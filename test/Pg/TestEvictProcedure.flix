///
/// HikariCP 5.1.0 の evict の手順ごとの結果（実測の表。設計 docs/design/cte-and-fatal.md の 2.4）。
/// fatal を拾った所で接続を「evict だけして close しない」理由はこの表にある。
///
///   手順                                   close の結果            evict の後の本物の接続への protocol の呼び出し   active   次の借り
///   1. evict → close（Tx の中で書いた後）   ok か NPE               1（close が本物に ROLLBACK を送る）              0        新しい pid
///   2. evict → close（Tx の中、書く前）     ok か NPE               0                                                0        新しい pid
///
/// 1 と 2 の close の結果は、evict した物理接続を HikariCP が別のスレッドで閉じるのとの競りで ok と
/// NullPointerException（PoolBase.resetConnectionState）のどちらにもなる。NPE の時は fatal がこの NPE にすり替わる。
///   3. 物理接続を閉じる → close（Tx の中）  PSQLException（閉じた） 1                                                0        新しい pid
///   4. evict だけ（Tx の中で書いた後）      -                       0                                                0        新しい pid
///   5. evict だけ（Tx の中、書く前）        -                       0                                                0        新しい pid
///   6. evict だけ（autocommit）             -                       0                                                0        新しい pid
///
mod TestEvictProcedure {

    use Sqlfx.DbError
    use Sqlfx.Jdbc
    use Sqlfx.Pool

    import com.zaxxer.hikari.HikariDataSource
    import java.lang.Class
    import java.lang.Object
    import java.lang.StackTraceElement
    import java.lang.Thread
    import java.lang.Throwable
    import java.sql.Connection

    ///
    /// 1 つの手順の結果（close の結果, protocol の呼び出しの数, active, 次の借り）。
    ///
    /// - close の結果: "ok" か投げた例外の class 名。close を呼ばない手順は "-"
    /// - protocol の呼び出しの数: evict（か物理接続を閉じた）後の、本物の接続への ROLLBACK / setAutoCommit / clearWarnings / commit
    /// - active: 手順の後の active
    /// - 次の借り: "new pid" / "same pid" / 失敗の 1 line
    ///
    type alias Outcome = (String, Int32, Int32, String)

    ///
    /// 手順の始め方。
    ///
    enum Start {
        /// BEGIN して 1 行書く
        case Written
        /// BEGIN だけ
        case Begun
        /// autocommit のまま
        case Autocommit
    }

    ///
    /// 手順の終わらせ方。
    ///
    enum Finish {
        /// evict してから close
        case EvictThenClose
        /// 物理接続を閉じてから close
        case PhysicalCloseThenClose
        /// evict だけ
        case EvictOnly
    }

    /// 1 つの手順を、新しいプールで走らせる。
    def measure(start: Start, finish: Finish): Outcome \ IO =
        let faulty = FaultyDataSource.open(FaultyDataSource.noFaults());
        let Pool.Pool(source) = faulty#pool;
        resetTable(faulty#pool);
        let conn = borrowOrBug(faulty#pool);
        let pid = pidOf(conn);
        match start {
            case Start.Written    => { conn.setAutoCommit(false); discard DbError.runWithKind(() -> Jdbc.executeStatement(conn, "INSERT INTO sqlfx_test_evict (name) VALUES ('x')", Nil)) }
            case Start.Begun      => conn.setAutoCommit(false)
            case Start.Autocommit => ()
        };
        let mark = List.length(FaultyDataSource.callsOf(faulty));
        let closed = match finish {
            case Finish.EvictThenClose         => { source.evictConnection(conn); closeOutcome(conn) }
            case Finish.PhysicalCloseThenClose => { closePhysical(conn); closeOutcome(conn) }
            case Finish.EvictOnly              => { source.evictConnection(conn); "-" }
        };
        awaitPhysicalClose(faulty, 40);
        let outcome = (closed, FaultyDataSource.protocolCallsAfter(mark, 1, faulty), Pool.stats(faulty#pool)#active, nextBorrow(faulty#pool, pid));
        Pool.close(faulty#pool);
        outcome

    /// 接続を借りる。借りられないのはテストの前提（PG が上がっている）が崩れている。
    def borrowOrBug(pool: Pool.Pool): Connection \ IO =
        match DbError.runWithKind(() -> Pool.borrow(pool)) {
            case Ok(found) => found
            case Err(kind) => bug!("borrow に失敗: ${DbError.describe(kind)}")
        }

    /// close を呼び、投げた物の class 名。投げなければ "ok"。ok と NPE は HikariCP の close のスレッドとの競りで
    /// どちらにもなるので、1 つの "ok or NPE" に読み替える。
    def closeOutcome(conn: Connection): String \ IO =
        try {
            conn.close();
            "ok or NPE"
        } catch {
            case error: Throwable =>
                let name: String = error.getClass().getName();
                if (name == "java.lang.NullPointerException") "ok or NPE" else name
        }

    /// HikariCP の proxy の下の、pgjdbc の物理接続を閉じる。
    def closePhysical(conn: Connection): Unit \ IO =
        let target: Class[Object] = Class.forName("org.postgresql.core.BaseConnection");
        let physical: Object = conn.unwrap(target);
        let pg: Connection = unchecked_cast(physical as Connection);
        pg.close()

    /// evict した物理接続を HikariCP が別のスレッドで閉じるのを、最大 tries × 50 ms 待つ。
    def awaitPhysicalClose(faulty: FaultyDataSource.Faulty, tries: Int32): Unit \ IO =
        if (tries <= 0 or List.memberOf("c1:close", FaultyDataSource.callsOf(faulty))) ()
        else { Thread.sleep(50i64); awaitPhysicalClose(faulty, tries - 1) }

    /// 次に借りた接続が、前と同じ backend pid か。
    def nextBorrow(pool: Pool.Pool, before: Int32): String \ IO =
        match DbError.runWithKind(() -> Pool.borrow(pool)) {
            case Err(kind) => DbError.describe(kind)
            case Ok(conn)  => {
                let pid = pidOf(conn);
                Jdbc.close(conn);
                if (pid == before) "same pid" else "new pid"
            }
        }

    /// 接続の backend pid。
    def pidOf(conn: Connection): Int32 \ IO =
        DbError.runWithKind(() -> Jdbc.fetchRows(conn, "SELECT pg_backend_pid() AS pid", Nil))
            |> Result.toOption
            |> Option.flatMap(List.head)
            |> Option.flatMap(row -> Sqlfx.Row.get("pid", row))
            |> Option.flatMap(value -> match value { case Sqlfx.SqlValue.SqlValue.Int32(n) => Some(n) case _ => None })
            |> Option.getWithDefault(-1)

    /// 表を作り直す。
    def resetTable(pool: Pool.Pool): Unit \ IO =
        discard DbError.runWithKind(() -> Pool.withConnection(pool, conn -> {
            discard Jdbc.executeStatement(conn, "DROP TABLE IF EXISTS sqlfx_test_evict", Nil);
            discard Jdbc.executeStatement(conn, "CREATE TABLE sqlfx_test_evict (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL)", Nil)
        }))

    @Test
    def testEvictProcedureTable(): Unit \ {Assert, IO} =
        let rows = List#{
            measure(Start.Written, Finish.EvictThenClose),
            measure(Start.Begun, Finish.EvictThenClose),
            measure(Start.Written, Finish.PhysicalCloseThenClose),
            measure(Start.Written, Finish.EvictOnly),
            measure(Start.Begun, Finish.EvictOnly),
            measure(Start.Autocommit, Finish.EvictOnly)
        };
        Assert.assertEq(
            expected = List#{
                ("ok or NPE", 1, 0, "new pid"),
                ("ok or NPE", 0, 0, "new pid"),
                ("org.postgresql.util.PSQLException", 1, 0, "new pid"),
                ("-", 0, 0, "new pid"),
                ("-", 0, 0, "new pid"),
                ("-", 0, 0, "new pid")
            },
            rows)


    /// 失敗を差し込む DataSource の marker と旗が、その所で決まった物を投げる（C4 のテストが空振りで通らないための前提）。
    ///
    ///   marker / 旗                             投げる物
    ///   fatal-on-prepare                         OutOfMemoryError（prepare の所）
    ///   fatal-after-execute                      OutOfMemoryError（1 行は書かれている）
    ///   driver-runtime-after-execute             IllegalStateException、stack trace の先頭は org.postgresql の frame
    ///   runtime-after-execute                    IllegalStateException
    ///   failSetAutoCommit で setAutoCommit(false) SQLException
    ///   failRollback で rollback()               SQLException
    ///   fatalOnCommit で commit()                OutOfMemoryError
    @Test
    def testFaultyDataSourceInjects(): Unit \ {Assert, IO} =
        let viaStatement = (marker: String) -> {
            let faulty = FaultyDataSource.open(FaultyDataSource.noFaults());
            resetTable(faulty#pool);
            let conn = borrowOrBug(faulty#pool);
            let thrown = thrownBy(() -> discard DbError.runWithKind(() -> Jdbc.executeStatement(conn, "INSERT INTO sqlfx_test_evict (name) VALUES ('x') /* inject: ${marker} */", Nil)));
            Jdbc.close(conn);
            let written = countRows(faulty#pool);
            Pool.close(faulty#pool);
            (thrown, written)
        };
        let viaConnection = (faults: FaultyDataSource.Faults, poke: Connection -> Unit \ IO) -> {
            let faulty = FaultyDataSource.open(faults);
            let conn = borrowOrBug(faulty#pool);
            let thrown = thrownBy(() -> poke(conn));
            let Pool.Pool(source) = faulty#pool;
            source.evictConnection(conn);
            Pool.close(faulty#pool);
            (thrown, -1)
        };
        let rows = List#{
            viaStatement("fatal-on-prepare"),
            viaStatement("fatal-after-execute"),
            viaStatement("driver-runtime-after-execute"),
            viaStatement("runtime-after-execute"),
            viaConnection({ failSetAutoCommit = true | FaultyDataSource.noFaults() }, conn -> conn.setAutoCommit(false)),
            viaConnection({ failRollback = true | FaultyDataSource.noFaults() }, conn -> { conn.setAutoCommit(false); conn.rollback() }),
            viaConnection({ fatalOnCommit = true | FaultyDataSource.noFaults() }, conn -> { conn.setAutoCommit(false); conn.commit() })
        };
        Assert.assertEq(
            expected = List#{
                ("java.lang.OutOfMemoryError", 0),
                ("java.lang.OutOfMemoryError", 1),
                ("java.lang.IllegalStateException at org.postgresql.core.v3.QueryExecutorImpl", 1),
                ("java.lang.IllegalStateException", 1),
                ("java.sql.SQLException", -1),
                ("java.sql.SQLException", -1),
                ("java.lang.OutOfMemoryError", -1)
            },
            rows)

    /// thunk が投げた物の class 名。stack trace の先頭が org.postgresql の frame なら、その class 名を添える。投げなければ "none"。
    def thrownBy(thunk: Unit -> Unit \ IO): String \ IO =
        try {
            thunk();
            "none"
        } catch {
            case error: Throwable =>
                let name: String = error.getClass().getName();
                let frames = error.getStackTrace();
                let top: String = if (Array.length(frames) == 0) "" else { let frame: StackTraceElement = Array.get(0, frames); frame.getClassName() };
                if (String.startsWith(prefix = "org.postgresql.", top)) "${name} at ${top}" else name
        }

    /// 表の行数。
    def countRows(pool: Pool.Pool): Int32 \ IO =
        DbError.runWithKind(() -> Pool.withConnection(pool, conn -> Jdbc.fetchRows(conn, "SELECT id FROM sqlfx_test_evict", Nil) |> List.length))
            |> Result.getWithDefault(-1)

}
