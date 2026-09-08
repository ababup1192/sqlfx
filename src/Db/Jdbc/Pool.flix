///
/// 接続プール。HikariCP を包み、借りた接続で SqlRead / SqlWrite を走らせて必ず返す。
/// Web のように接続を使い回す所はこちら、CLI やテストのように 1 回だけ開くなら `Jdbc.withConnection`。
///
mod Pool {

    import java.lang.StackOverflowError
    import java.lang.Throwable
    import java.lang.VirtualMachineError
    import java.sql.Connection
    import java.sql.SQLException
    import com.zaxxer.hikari.HikariConfig
    import com.zaxxer.hikari.HikariDataSource
    import com.zaxxer.hikari.HikariPoolMXBean
    import org.postgresql.ds.PGSimpleDataSource

    ///
    /// 開いたプール。`open` で作り、`close` で全接続を閉じる。
    ///
    pub enum Pool {
        case Pool(HikariDataSource)
    }

    ///
    /// プールの設定。
    ///
    /// - `connection`: 接続先と認証
    /// - `maxConnections`: 同時に使う接続の上限。超えた分は `borrowTimeoutMs` まで待つ
    /// - `borrowTimeoutMs`: 借りるのを待つ上限。超えたら TransientDbErr.timeout
    /// - `leakDetectionThresholdMs`: 借りたまま返さない接続を HikariCP が SLF4J の warn に出すまでの ms。0 で無効。
    ///   HikariCP は 2000 未満を黙って無効にするので、0 でなければ 2000 以上に丸める
    ///
    pub type alias PoolConfig = { connection = Jdbc.ConnectionConfig, maxConnections = Int32, borrowTimeoutMs = Int32, leakDetectionThresholdMs = Int32 }

    ///
    /// プールの数字。`/health` のような所で枯渇や漏れを見るのに使う。
    ///
    /// - `active`: 借りられている接続
    /// - `idle`: 空いている接続
    /// - `waiting`: 借りるのを待っているスレッド
    /// - `total`: 開いている接続（active + idle）
    /// - `max`: 設定の上限（`maxConnections`）
    ///
    pub type alias PoolStats = { active = Int32, idle = Int32, waiting = Int32, total = Int32, max = Int32 }

    ///
    /// 既定の設定。接続数 10、待ち 5 秒、漏れの検出は無効。
    ///
    pub def defaultConfig(connection: Jdbc.ConnectionConfig): PoolConfig =
        { connection = connection, maxConnections = 10, borrowTimeoutMs = 5000, leakDetectionThresholdMs = 0 }

    ///
    /// HikariCP が受け付ける最小の漏れ検出のしきい値（ms）。
    ///
    def minLeakDetectionThresholdMs(): Int32 = 2000

    ///
    /// プールを開く。この時点では接続しない（最初の borrow で開く）。
    ///
    /// WhyNot: `initializationFailTimeout` を -1 にするのは、既定の fail-fast だと `open` の時点で接続しに行き、
    /// 届かなければ Java の例外を投げて `TransientDbErr` の道を通らないため。届くかは最初の `borrow` で分かる。
    ///
    /// WhyNot: HikariCP に `jdbcUrl` を渡さないのは、ドライバをクラス名で探す経路が Flix の Maven クラスローダで
    /// 効かないから（`Jdbc.connect` と同じ理由）。pgjdbc の DataSource をこちらで作って渡す。
    ///
    pub def open(config: PoolConfig): Pool \ IO =
        let source = new PGSimpleDataSource();
        source.setUrl(config#connection#url);
        source.setUser(config#connection#user);
        source.setPassword(config#connection#password);
        let hikari = new HikariConfig();
        hikari.setDataSource(source);
        hikari.setMaximumPoolSize(config#maxConnections);
        hikari.setConnectionTimeout(Int32.toInt64(config#borrowTimeoutMs));
        hikari.setInitializationFailTimeout(-1i64);
        hikari.setLeakDetectionThreshold(Int32.toInt64(roundLeakDetectionThreshold(config#leakDetectionThresholdMs)));
        Pool.Pool(new HikariDataSource(hikari))

    ///
    /// 0 以下は 0（無効）、それ以外は 2000 以上に丸める。
    ///
    def roundLeakDetectionThreshold(ms: Int32): Int32 =
        if (ms <= 0) 0 else Int32.max(minLeakDetectionThresholdMs(), ms)

    ///
    /// HikariCP に渡っている漏れ検出のしきい値（ms）。0 なら無効。
    ///
    pub def leakDetectionThresholdMs(pool: Pool): Int32 \ IO =
        let Pool.Pool(source) = pool;
        let threshold: Int64 = source.getLeakDetectionThreshold();
        Int64.clampToInt32(min = 0, max = Int32.maxValue(), threshold)

    ///
    /// 今の数字。
    ///
    /// WhyNot: MXBean が null の時に例外にしないのは、プールがまだ 1 本も開いていない（`initializationFailTimeout` -1 で
    /// 遅延している）時や閉じた後にも `/health` は読みに来るので、その時は「0 本」と答える方が扱いやすいため。
    ///
    pub def stats(pool: Pool): PoolStats \ IO =
        let Pool.Pool(source) = pool;
        let max: Int32 = source.getMaximumPoolSize();
        let bean: HikariPoolMXBean = source.getHikariPoolMXBean();
        if (Object.isNull(bean))
            { active = 0, idle = 0, waiting = 0, total = 0, max = max }
        else
            { active = bean.getActiveConnections(), idle = bean.getIdleConnections(), waiting = bean.getThreadsAwaitingConnection(), total = bean.getTotalConnections(), max = max }

    ///
    /// 全接続を閉じる。終了時に 1 回。
    ///
    pub def close(pool: Pool): Unit \ IO =
        let Pool.Pool(source) = pool;
        source.close()

    ///
    /// 接続を借りる。上限まで使われていて `borrowTimeoutMs` 待っても空かなければ TransientDbErr.timeout、
    /// DB に繋げなければ TransientDbErr.connectionLost。
    ///
    /// WhyNot: 例外の message で分けないのは、HikariCP が「借り待ちの上限」も「DB に届かない」も
    /// 同じ "request timed out" の文言で出すため。借りに失敗した時点の `stats` と cause の連鎖で分ける。
    ///
    pub def borrow(pool: Pool): Connection \ {IO, TransientDbErr} =
        let Pool.Pool(source) = pool;
        try {
            source.getConnection()
        } catch {
            case e: SQLException =>
                let msg: String = e.getMessage();
                let text = if (Object.isNull(msg)) "" else msg;
                let causes = causeClassNames(unchecked_cast(e as Throwable), maxCauseDepth());
                match borrowFailureKind(text, causes, sqlStateOf(e), stats(pool)) {
                    case DbError.DbErrorKind.Timeout(ms)     => TransientDbErr.timeout(ms)
                    case DbError.DbErrorKind.ConnectionLost(m) => TransientDbErr.connectionLost(m)
                    case kind                                => TransientDbErr.connectionLost("${kind}")
                }
        }

    ///
    /// borrow が失敗した理由を分ける（純粋）。
    ///
    /// - cause の連鎖に接続の失敗（ConnectException / SocketTimeoutException / SQLState が "08" の PSQLException）があれば connectionLost
    /// - そうでなく pool が満杯（`active >= max`）なら timeout（借り待ちの上限）
    /// - それ以外は、pool は空いているのに接続が作れなかったので connectionLost
    ///
    pub def borrowFailureKind(message: String, causes: List[String], sqlState: Option[String], poolStats: PoolStats): DbError.DbErrorKind =
        if (isConnectionFailure(causes, sqlState))
            DbError.DbErrorKind.ConnectionLost(message)
        else if (poolStats#max > 0 and poolStats#active >= poolStats#max)
            DbError.DbErrorKind.Timeout(0)
        else
            DbError.DbErrorKind.ConnectionLost(message)

    ///
    /// cause の連鎖が「DB に届かなかった」事を示すか。
    ///
    def isConnectionFailure(causes: List[String], sqlState: Option[String]): Bool =
        let hasClass = name -> List.memberOf(name, causes);
        let psqlIsConnectionClass =
            hasClass("org.postgresql.util.PSQLException")
                and sqlState |> Option.exists(state -> String.startsWith(prefix = "08", state));
        hasClass("java.net.ConnectException")
            or hasClass("java.net.SocketTimeoutException")
            or psqlIsConnectionClass

    ///
    /// cause の連鎖をたどる上限。
    ///
    def maxCauseDepth(): Int32 = 8

    ///
    /// 例外とその cause の連鎖の class 名。
    ///
    def causeClassNames(t: Throwable, depth: Int32): List[String] \ IO =
        if (depth <= 0 or Object.isNull(t))
            Nil
        else {
            let name: String = t.getClass().getName();
            name :: causeClassNames(t.getCause(), depth - 1)
        }

    ///
    /// 連鎖の中の pgjdbc の例外の SQLState。無ければ SQLException 自身の物。
    ///
    def sqlStateOf(e: SQLException): Option[String] \ IO =
        let state: String = e.getSQLState();
        if (Object.isNull(state)) psqlSqlState(e.getCause(), maxCauseDepth()) else Some(state)

    ///
    /// 連鎖をたどって最初の PSQLException の SQLState を取る。
    ///
    def psqlSqlState(t: Throwable, depth: Int32): Option[String] \ IO =
        if (depth <= 0 or Object.isNull(t))
            None
        else {
            let name: String = t.getClass().getName();
            if (name == "org.postgresql.util.PSQLException") {
                let psql: SQLException = unchecked_cast(t as SQLException);
                let state: String = psql.getSQLState();
                if (Object.isNull(state)) psqlSqlState(t.getCause(), depth - 1) else Some(state)
            } else
                psqlSqlState(t.getCause(), depth - 1)
        }

    ///
    /// 接続を借りて thunk を走らせ、成功でも失敗でも必ず返す。失敗はそのまま再送出する。
    /// Tx が要るなら thunk の中で `Tx.withTx(conn, ...)`。制約違反の翻訳（`onConstraint`）は Tx の外で。
    ///
    pub def withConnection(pool: Pool, thunk: Connection -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        let conn = borrow(pool);
        let outcome = DbError.runWithKind(() -> Jdbc.runWithConnection(conn, () -> thunk(conn)));
        Jdbc.close(conn);
        match outcome {
            case Ok(value) => value
            case Err(kind) => DbError.raise(kind)
        }

    ///
    /// 最初の SQL が来た時に初めて接続を借りて BEGIN し、thunk が終わったら COMMIT（失敗なら ROLLBACK）して返す。
    /// SQL を 1 本も出さない thunk はプールに触らない。GraphQL のリゾルバのように「DB を使うかもしれない」単位を
    /// 1 つの Tx にしたい所で使う。ネストは `withTx` と同じく未対応。
    /// thunk が JVM の例外を投げても ROLLBACK して接続を返し、`DbErr` の `Other` として上げる
    /// （`OutOfMemoryError` のような `VirtualMachineError` はそのまま再送出）。
    ///
    pub def withLazyTx(pool: Pool, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        withLazyTxAfterBegin(pool, () -> (), thunk)

    ///
    /// `withLazyTx` に加えて、BEGIN の直後（thunk の最初の SQL の前）に onBegin を同じ接続・同じ Tx で 1 回だけ流す。
    /// `SELECT set_config('app.tenant', $1, true)` のように、Tx の間だけ効く印を置くのに使う。
    /// SQL を出さない thunk では onBegin も呼ばれない（接続を借りないため）。
    ///
    /// WhyNot: 印を Tx の外（接続を借りた直後）で置かないのは、`set_config(..., true)` は Tx の終わりで消えるので
    /// BEGIN の後でないと効かず、プールに返した接続へ印が残る事も無いため。
    ///
    pub def withLazyTxAfterBegin(pool: Pool, onBegin: Unit -> Unit \ ef2, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + (ef2 - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        region rc {
            let slot = Ref.fresh(rc, None);
            def open() = match Ref.get(slot) {
                case Some(found) => found
                case None        => {
                    let found = borrow(pool);
                    Tx.begin(found);
                    Ref.put(Some(found), slot);
                    // 印を置く SQL は開いたばかりの接続で流す（この時点で slot は埋まっているので、再帰しない）
                    runOn(found, onBegin);
                    found
                }
            };
            let outcome = DbError.runWithKind(() ->
                run guarded(thunk) with handler SqlRead {
                    def fetch(sql, params, resume) = resume(DbError.runWithKind(() -> Jdbc.fetchRows(open(), sql, params)))
                } with handler SqlWrite {
                    def execute(sql, params, resume)          = resume(DbError.runWithKind(() -> Jdbc.executeStatement(open(), sql, params)))
                    def executeReturning(sql, params, resume) = resume(DbError.runWithKind(() -> Jdbc.fetchRows(open(), sql, params)))
                });
            let finished = match (Ref.get(slot), outcome) {
                case (None, _)             => outcome
                case (Some(found), Ok(_))  => {
                    let committed = DbError.runWithKind(() -> Tx.commit(found));
                    Jdbc.close(found);
                    Result.flatMap(_ -> outcome, committed)
                }
                case (Some(found), Err(_)) => { Tx.rollback(found); Jdbc.close(found); outcome }
            };
            match finished {
                case Ok(value) => value
                case Err(kind) => DbError.raise(kind)
            }
        }

    ///
    /// thunk を走らせ、JVM の例外（Java interop、VerifyError、写しのコードの RuntimeException）を
    /// `DbErr` に変えて返す。JVM 自体が壊れている物（`isFatal`）はそのまま再送出する。
    ///
    /// WhyNot: catch を `run … with handler SqlRead` の外に置かないのは、handler の外に置いた catch を
    /// 例外が素通りするため（2026-09-08 に実測）。SQL を出した後に投げられた例外も拾えるよう、最内側に置く。
    ///
    /// WhyNot: catch の腕で op（`DbError.raise`）を直に呼ばないのは、JVM の VerifyError になるため。
    /// 腕では値だけ返し、catch を抜けてから raise する。
    ///
    def guarded(thunk: Unit -> a \ ef): a \ ef + IO + {TransientDbErr, DbErr} =
        let caught = try {
            Ok(thunk())
        } catch {
            case error: Throwable => Err(error)
        };
        match caught {
            case Ok(value)    => value
            case Err(error)   =>
                if (isFatal(error)) throw error
                else DbError.raise(DbError.DbErrorKind.Other(describeThrowable(error)))
        }

    ///
    /// 飲み込んではいけない物か。`VirtualMachineError`（OutOfMemoryError / InternalError）は true。
    ///
    /// WhyNot: StackOverflowError を fatal にしないのは、VirtualMachineError の子ではあるが 1 つの Tx の深い再帰で
    /// 起きる物で、その Tx を巻き戻せば JVM は続けられるため。
    ///
    /// WhyNot: `instanceof` でなく throw して catch で分けるのは、Flix に型の判定式が無く、catch の並びなら
    /// 子クラスを先に書けるため。
    ///
    def isFatal(error: Throwable): Bool \ IO =
        try {
            throw error
        } catch {
            case _: StackOverflowError  => false
            case _: VirtualMachineError => true
            case _: Throwable           => false
        }

    ///
    /// 例外の 1 行。message があればそれ、null ならクラス名（VerifyError は message が null の事がある）。
    ///
    def describeThrowable(error: Throwable): String \ IO =
        let message: String = error.getMessage();
        if (Object.isNull(message)) error.getClass().getName() else message

    ///
    /// 決まった接続で thunk の SQL を流す（Tx の管理はしない）。
    ///
    def runOn(conn: Connection, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        run thunk() with handler SqlRead {
            def fetch(sql, params, resume) = resume(DbError.runWithKind(() -> Jdbc.fetchRows(conn, sql, params)))
        } with handler SqlWrite {
            def execute(sql, params, resume)          = resume(DbError.runWithKind(() -> Jdbc.executeStatement(conn, sql, params)))
            def executeReturning(sql, params, resume) = resume(DbError.runWithKind(() -> Jdbc.fetchRows(conn, sql, params)))
        }

}
