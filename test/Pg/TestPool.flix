use SqlValue.SqlValue
use DbError.DbFailure

// Pool: HikariCP を包んだ接続プール。実 PG で、使い回し・枯渇時の待ち・閉じた後を確かめる。

def smallPool(borrowTimeoutMs: Int32): Pool.Pool \ IO =
    Pool.open({ connection = pgConfig(), maxConnections = 1, borrowTimeoutMs = borrowTimeoutMs })

/// 借りて返した接続は次も同じ物が来る（サーバ側の backend pid が一致する）。
@Test
def testPoolReusesConnection(): Unit \ {Assert, IO} =
    let pool = smallPool(1000);
    let pids = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> {
        let first = Pool.withConnection(pool, _ -> Sql.fetchOneAs(Decoder.int32("pid"), "SELECT pg_backend_pid() AS pid", Nil));
        let second = Pool.withConnection(pool, _ -> Sql.fetchOneAs(Decoder.int32("pid"), "SELECT pg_backend_pid() AS pid", Nil));
        (first, second)
    }));
    Pool.close(pool);
    Assert.assertEq(expected = Ok(true), pids |> Result.map(pair -> { let (first, second) = pair; Option.nonEmpty(first) and first == second }))

/// 上限まで借りている間に更に借りると、待ち時間の後に TransientDbErr.timeout になる。外側の接続は返る。
@Test
def testPoolBorrowTimesOutWhenExhausted(): Unit \ {Assert, IO} =
    let pool = smallPool(300);
    let inner = RawSql.runWithAllow(() -> DbError.runWithFailure(() ->
        Pool.withConnection(pool, _ ->
            DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> Sql.fetch("SELECT 1", Nil) |> List.length)))));
    let afterwards = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> Sql.fetch("SELECT 1", Nil) |> List.length)));
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(Err(DbFailure.Transient("timeout 0"))), Ok(1)), (inner, afterwards))

/// 閉じたプールから借りると TransientDbErr.connectionLost。
@Test
def testPoolClosedIsConnectionLost(): Unit \ {Assert, IO} =
    let pool = smallPool(1000);
    Pool.close(pool);
    let result = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> Sql.fetch("SELECT 1", Nil) |> List.length)))
        |> Result.mapErr(failure -> String.startsWith(prefix = "Transient(connectionLost", "${failure}"));
    Assert.assertEq(expected = Err(true), result)
