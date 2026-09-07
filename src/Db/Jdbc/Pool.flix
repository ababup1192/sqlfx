///
/// 接続プール。HikariCP を包み、借りた接続で SqlRead / SqlWrite を走らせて必ず返す。
/// Web のように接続を使い回す所はこちら、CLI やテストのように 1 回だけ開くなら `Jdbc.withConnection`。
///
mod Pool {

    import java.sql.Connection
    import java.sql.SQLException
    import com.zaxxer.hikari.HikariConfig
    import com.zaxxer.hikari.HikariDataSource
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
    ///
    pub type alias PoolConfig = { connection = Jdbc.ConnectionConfig, maxConnections = Int32, borrowTimeoutMs = Int32 }

    ///
    /// 既定の設定。接続数 10、待ち 5 秒。
    ///
    pub def defaultConfig(connection: Jdbc.ConnectionConfig): PoolConfig =
        { connection = connection, maxConnections = 10, borrowTimeoutMs = 5000 }

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
        Pool.Pool(new HikariDataSource(hikari))

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
    pub def borrow(pool: Pool): Connection \ {IO, TransientDbErr} =
        let Pool.Pool(source) = pool;
        try {
            source.getConnection()
        } catch {
            case e: SQLException =>
                let msg: String = e.getMessage();
                let text = if (Object.isNull(msg)) "" else msg;
                if (String.contains(substr = "request timed out", text))
                    TransientDbErr.timeout(0)
                else
                    TransientDbErr.connectionLost(text)
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
                run thunk() with handler SqlRead {
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
