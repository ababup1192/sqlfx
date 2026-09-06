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

// ---- withLazyTx ----

/// SQL を 1 本も出さない thunk はプールに触らない: パスワードが違うプールでも成功し、SELECT を出す thunk だけ Transient（HikariCP は認証失敗を待ってから timeout にする）になる。
@Test
def testPoolLazyTxDoesNotBorrowWithoutSql(): Unit \ {Assert, IO} =
    let config = pgConfig();
    let pool = Pool.open({ connection = { url = config#url, user = config#user, password = "wrong" }, maxConnections = 1, borrowTimeoutMs = 1000 });
    let pure = DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> 42));
    let reading = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> Sql.fetch("SELECT 1", Nil) |> List.length)))
        |> Result.mapErr(failure -> String.startsWith(prefix = "Transient(", "${failure}"));
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(42), Err(true)), (pure, reading))

/// SQL を出す thunk は 1 つの Tx になる: DbErr で ROLLBACK され、その前の INSERT が残らない。正常なら COMMIT され別接続から見える。
///
///   BEGIN  INSERT a  INSERT a(重複) → ROLLBACK   … 0 行
///   BEGIN  INSERT b                 → COMMIT     … 1 行
@Test
def testPoolLazyTxRollsBackAndCommits(): Unit \ {Assert, IO} =
    let pool = smallPool(1000);
    let result = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> {
        Pool.withConnection(pool, _ -> resetUsers());
        let failed = DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
            discard Sql.execute("INSERT INTO sqlfx_test_users (name, email, created_at) VALUES ('a', 'x@example.com', now())", Nil);
            discard Sql.execute("INSERT INTO sqlfx_test_users (name, email, created_at) VALUES ('b', 'x@example.com', now())", Nil)
        }));
        let afterFailure = Pool.withConnection(pool, _ -> Sql.fetch("SELECT id FROM sqlfx_test_users", Nil) |> List.length);
        Pool.withLazyTx(pool, () -> discard Sql.execute("INSERT INTO sqlfx_test_users (name, created_at) VALUES ('b', now())", Nil));
        let afterCommit = Pool.withConnection(pool, _ -> Sql.fetch("SELECT id FROM sqlfx_test_users", Nil) |> List.length);
        (failed, afterFailure, afterCommit)
    }));
    Pool.close(pool);
    Assert.assertEq(expected = Ok((Err(DbFailure.Permanent("uniqueViolation sqlfx_test_users_email_key")), 0, 1)), result)
