use SqlValue.SqlValue
use DbError.DbFailure

// Pool: HikariCP を包んだ接続プール。実 PG で、使い回し・枯渇時の待ち・閉じた後を確かめる。

def smallPool(borrowTimeoutMs: Int32): Pool.Pool \ IO =
    Pool.open({ maxConnections = 1, borrowTimeoutMs = borrowTimeoutMs | Pool.defaultConfig(pgConfig()) })

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
    let pool = Pool.open({ maxConnections = 1, borrowTimeoutMs = 1000 | Pool.defaultConfig({ url = config#url, user = config#user, password = "wrong" }) });
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

/// onBegin は最初の SQL の前に同じ Tx で 1 回流れ、`set_config(..., true)` の印が thunk から見える。SQL を出さない thunk では流れない。
///
///   BEGIN  set_config('app.tenant', '7')  SELECT current_setting  → '7'
///   （SQL 無し）                                                    → onBegin 未実行（カウンタ 0）
@Test
def testPoolLazyTxAfterBegin(): Unit \ {Assert, IO} =
    let pool = smallPool(1000);
    let stamp = () -> discard Sql.fetch("SELECT set_config('app.tenant', '7', true)", Nil);
    let seen = RawSql.runWithAllow(() -> DbError.runWithFailure(() ->
        Pool.withLazyTxAfterBegin(pool, stamp, () -> Sql.fetchOneAs(Decoder.str("tenant"), "SELECT current_setting('app.tenant', true) AS tenant", Nil))));
    let afterwards = RawSql.runWithAllow(() -> DbError.runWithFailure(() ->
        Pool.withLazyTx(pool, () -> Sql.fetchOneAs(Decoder.str("tenant"), "SELECT coalesce(current_setting('app.tenant', true), '') AS tenant", Nil))));
    let counter = Ref.fresh(Static, 0);
    let pure = DbError.runWithFailure(() -> Pool.withLazyTxAfterBegin(pool, () -> Ref.put(Ref.get(counter) + 1, counter), () -> 42));
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(Some("7")), Ok(Some("")), Ok(42), 0), (seen, afterwards, pure, Ref.get(counter)))

// ---- stats ----

/// 借りている間は active が 1 で total も 1、返した後は active が 0 で idle に戻る。max は設定値。
///
///   open            active 0
///   withConnection  active 1  total 1
///   返した後         active 0  idle 1
@Test
def testPoolStatsFollowBorrowAndReturn(): Unit \ {Assert, IO} =
    let pool = smallPool(1000);
    let inside = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> {
        discard Sql.fetch("SELECT 1", Nil);
        let stats = Pool.stats(pool);
        (stats#active, stats#total, stats#max)
    })));
    let after = Pool.stats(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Ok((1, 1, 1)), 0, 1), (inside, after#active, after#idle))

/// DB に届かない DSN の pool から借りると、pool は空いているので TransientDbErr.connectionLost（timeout ではない）。
@Test
def testPoolUnreachableIsConnectionLost(): Unit \ {Assert, IO} =
    let pool = Pool.open({ maxConnections = 2, borrowTimeoutMs = 250 | Pool.defaultConfig({ url = "jdbc:postgresql://127.0.0.1:1/none", user = "none", password = "none" }) });
    let result = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> Sql.fetch("SELECT 1", Nil) |> List.length)))
        |> Result.mapErr(failure -> String.startsWith(prefix = "Transient(connectionLost", "${failure}"));
    Pool.close(pool);
    Assert.assertEq(expected = Err(true), result)
