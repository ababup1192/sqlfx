import java.lang.RuntimeException
import java.lang.Thread

use SqlValue.SqlValue
use DbError.DbErrorKind
use DbError.Failure
use DbError.TransientKind

// Pool の接続の漏れ: 失敗の道ごとに、接続がプールに戻り（active 0）、次の借りが待たずに通るかを実 PG で見る。
// プールの大きさを 1 にするので、1 本でも漏れれば次の借りは borrowTimeoutMs の後に Timeout になる。

/// 大きさ 1、借り待ち 300 ms のプール。
def leakPool(): Pool.Pool \ IO =
    Pool.open({ maxConnections = 1, borrowTimeoutMs = 300 | Pool.defaultConfig(pgConfig()) })

/// 漏れの検出: 今の active と、次の借りの結果（漏れていれば Timeout(0)）。
def probe(pool: Pool.Pool): (Int32, Result[Failure, Int32]) \ IO =
    let active = Pool.stats(pool)#active;
    let next = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> Sql.fetch("SELECT 1", Nil) |> List.length)));
    (active, next)

/// 漏れのテスト用の表を作り直す。
def resetLeakTable(pool: Pool.Pool): Unit \ IO =
    discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> {
        discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_leaks", Nil);
        discard Sql.execute("CREATE TABLE sqlfx_test_leaks (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE)", Nil)
    })))

/// 表の行数。
def countLeakRows(pool: Pool.Pool): Result[Failure, Int32] \ IO =
    RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> Sql.fetch("SELECT id FROM sqlfx_test_leaks", Nil) |> List.length)))

/// 1 行入れる。
def insertLeakRow(name: String): Unit \ DbWrite + RawSql =
    discard Sql.execute("INSERT INTO sqlfx_test_leaks (name, email) VALUES ($1, $2)", List#{SqlValue.Str(name), SqlValue.Str("${name}@example.com")})

/// 利用側の業務エラー（テスト用）。
eff LeakBizErr {
    def fail(): Void
}

/// シナリオを走らせて（結果は捨てる）、その後の漏れを見る。
def runScenario(pool: Pool.Pool, scenario: Unit -> Unit \ IO): (Int32, Result[Failure, Int32]) \ IO =
    scenario();
    probe(pool)

/// 失敗の道ごとに、接続はプールに戻り（active 0）、次の借りは待たずに通る（Ok 1）。
///
///   a. thunk が JVM の例外を投げる                              → ROLLBACK
///   b. withLazyTxResult の thunk が Err を返す                   → ROLLBACK
///   c. 利用側の handler の内側の Db.guard が例外を受ける          → ROLLBACK
///   d. onBegin（印を置く処理）の SQL が失敗する（DbErr）          → ROLLBACK
///   e. withConnectionTimeout が借り待ちを諦めた後に接続が返る     → 遅れて届いた接続は閉じる
///   f. Tx の中の SQL の失敗を Db.attempt で受け、その後の SQL が aborted で失敗 → ROLLBACK
@Test
def testPoolConnectionReturnsOnEveryFailurePath(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let scenarios: List[Unit -> Unit \ IO] = List#{
        () -> discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> { insertLeakRow("a"); throw new RuntimeException("boom") }))),
        () -> discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTxResult(pool, () -> { insertLeakRow("b"); Err("biz") }))),
        () -> discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTxResult(pool, () ->
            run { Ok(Db.guard(() -> { insertLeakRow("c"); throw new RuntimeException("boom") })) } with handler LeakBizErr { def fail(_resume) = Err("biz") }))),
        () -> discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTxAfterBegin(pool, () -> discard Sql.fetch("SELECT * FROM sqlfx_no_such_table", Nil), () -> insertLeakRow("d")))),
        () -> {
            discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ ->
                DbError.runWithFailure(() -> Pool.withConnectionTimeout(pool, 100, _ -> Sql.fetch("SELECT 1", Nil) |> List.length)))));
            // 遅れて届いた接続を閉じる spawn が走り切るのを待つ
            Thread.sleep(500i64)
        },
        () -> discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
            insertLeakRow("g");
            discard Db.attempt(() -> insertLeakRow("g"));
            insertLeakRow("h")
        })))
    };
    let probes = scenarios |> List.map(scenario -> runScenario(pool, scenario));
    let rows = countLeakRows(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (List.repeat(6, (0, Ok(1))), Ok(0)), (probes, rows))

/// 利用側が業務エラーの handler を withLazyTx の外に張り、thunk の中で再開しない op を呼ぶと、
/// COMMIT / ROLLBACK と接続の返却が飛んで接続が漏れる（README §6 の「業務エラーを Tx の外で受けてはいけない」）。
///
///   [LeakBizErr の handler [withLazyTx: INSERT; LeakBizErr.fail]] → Err("biz") は返るが active 1 のまま、次の借りは Timeout(0)
@Test
def testPoolHandlerOutsideLazyTxLeaksConnection(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome: Result[Failure, Result[String, Unit]] = RawSql.runWithAllow(() -> DbError.runWithFailure(() ->
        run {
            Ok(Pool.withLazyTx(pool, () -> { insertLeakRow("outside"); LeakBizErr.fail() }))
        } with handler LeakBizErr {
            def fail(_resume) = Err("biz")
        }));
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(Err("biz")), 1, Err(Failure.Transient(TransientKind.Timeout(0)))), (outcome, active, next))

/// 利用側が thunk の中で handler を張り、Db.guard を置かずに SQL の後で例外を投げると、ライブラリの catch は届かず
/// 例外が withLazyTx の外まで抜け、COMMIT / ROLLBACK と接続の返却が飛ぶ（README §6 の「触ってはいけない形」）。
///
///   [withLazyTx [LeakBizErr の handler: INSERT; throw]] → 例外が抜ける、active 1 のまま、次の借りは Timeout(0)
@Test
def testPoolLazyTxHandlerInsideWithoutGuardLeaks(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let escaped =
        try {
            discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTxResult(pool, () ->
                run {
                    insertLeakRow("inside");
                    throw new RuntimeException("boom")
                } with handler LeakBizErr {
                    def fail(_resume) = Err("biz")
                })));
            false
        } catch {
            case _: RuntimeException => true
        };
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (true, 1, Err(Failure.Transient(TransientKind.Timeout(0)))), (escaped, active, next))

/// onBegin（印を置く処理）が JVM の例外を投げても、thunk の例外と同じく Other になり、接続はプールに返る。
///
///   BEGIN  onBegin: throw → ROLLBACK … Other("onBegin boom")、active 0、次の借りは通る
@Test
def testPoolLazyTxAfterBeginExceptionReturnsConnection(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome: Result[String, Unit] =
        try {
            RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTxAfterBegin(pool, () -> throw new RuntimeException("onBegin boom"), () -> insertLeakRow("e"))))
                |> Result.mapErr(DbError.describeFailure)
        } catch {
            case _: RuntimeException => Err("escaped")
        };
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Err("other onBegin boom"), 0, Ok(1)), (outcome, active, next))

// ---- Retry と Tx ----

/// statement_timeout を 1 回目だけ踏ませる thunk。呼んだ回数を counter に記録する。
def flakyInsert(counter: Ref[Int32, Static]): Unit \ Db + RawSql + IO =
    Ref.put(Ref.get(counter) + 1, counter);
    insertLeakRow("retry-${Ref.get(counter)}");
    if (Ref.get(counter) == 1) {
        discard Sql.execute("SET LOCAL statement_timeout = 50", Nil);
        discard Sql.fetch("SELECT pg_sleep(1)", Nil)
    } else ()

/// 一時障害の再試行は Tx ごと: 1 回目の INSERT は ROLLBACK で消え、2 回目だけ COMMIT される。接続は毎回返る（大きさ 1 のプールで 2 回目が通る）。
///
///   attempt 1: BEGIN INSERT retry-1  statement_timeout → ROLLBACK
///   attempt 2: BEGIN INSERT retry-2                    → COMMIT
@Test
def testPoolRetryReopensTxPerAttempt(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let counter = Ref.fresh(Static, 0);
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Retry.withRetry(3, () -> Pool.withLazyTx(pool, () -> flakyInsert(counter)))));
    let names = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> Sql.fetchAs(Decoder.str("name"), "SELECT name FROM sqlfx_test_leaks ORDER BY id", Nil))));
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(()), 2, Ok(List#{"retry-2"}), 0, Ok(1)), (outcome, Ref.get(counter), names, active, next))

/// 毎回 statement_timeout なら RetryExhausted(Timeout(0), attempts)。全部 ROLLBACK され、接続も返る。
@Test
def testPoolRetryExhaustedRollsBackAll(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome: Result[Failure, Unit] = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Retry.withRetry(2, () -> Pool.withLazyTx(pool, () -> {
        insertLeakRow("exhausted");
        discard Sql.execute("SET LOCAL statement_timeout = 50", Nil);
        discard Sql.fetch("SELECT pg_sleep(1)", Nil)
    }))));
    let rows = countLeakRows(pool);
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Err(Failure.Permanent(DbErrorKind.RetryExhausted(TransientKind.Timeout(0), 2))), Ok(0), 0, Ok(1)), (outcome, rows, active, next))

// ---- 借りるのは 1 回 ----

/// withLazyTx は SQL を 2 本出しても借りるのは 1 回: 2 本とも同じ backend pid で、thunk の中の active は 1、total も 1。
@Test
def testPoolLazyTxBorrowsOnceForManyStatements(): Unit \ {Assert, IO} =
    let pool = leakPool();
    let seen = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        let first = Sql.fetchOneAs(Decoder.int32("pid"), "SELECT pg_backend_pid() AS pid", Nil);
        let second = Sql.fetchOneAs(Decoder.int32("pid"), "SELECT pg_backend_pid() AS pid", Nil);
        let stats = Pool.stats(pool);
        (Option.nonEmpty(first) and first == second, stats#active, stats#total)
    })));
    Pool.close(pool);
    Assert.assertEq(expected = Ok((true, 1, 1)), seen)

// ---- COMMIT で失敗する Tx ----

/// DEFERRABLE INITIALLY DEFERRED の unique は COMMIT の時に失敗する。COMMIT の失敗も UniqueViolation として返り、
/// 行は残らず、接続は autocommit に戻って返る（次の借りで INSERT が普通に COMMIT される）。
///
///   BEGIN  INSERT x  INSERT x（重複。まだ通る）  COMMIT → uniqueViolation … 0 行
///   次の借り INSERT y（autocommit）                            … 1 行
@Test
def testPoolLazyTxCommitFailureIsTranslatedAndReturnsConnection(): Unit \ {Assert, IO} =
    let pool = leakPool();
    discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> {
        discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_deferred", Nil);
        discard Sql.execute("CREATE TABLE sqlfx_test_deferred (email TEXT, CONSTRAINT sqlfx_test_deferred_email_key UNIQUE (email) DEFERRABLE INITIALLY DEFERRED)", Nil)
    })));
    let failed: Result[Failure, Unit] = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        discard Sql.execute("INSERT INTO sqlfx_test_deferred (email) VALUES ('x')", Nil);
        discard Sql.execute("INSERT INTO sqlfx_test_deferred (email) VALUES ('x')", Nil)
    })));
    let afterwards = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> {
        let remaining = Pool.withConnection(pool, _ -> Sql.fetch("SELECT email FROM sqlfx_test_deferred", Nil) |> List.length);
        Pool.withConnection(pool, _ -> discard Sql.execute("INSERT INTO sqlfx_test_deferred (email) VALUES ('y')", Nil));
        let committed = Pool.withConnection(pool, _ -> Sql.fetch("SELECT email FROM sqlfx_test_deferred", Nil) |> List.length);
        (remaining, committed)
    }));
    let active = Pool.stats(pool)#active;
    Pool.close(pool);
    Assert.assertEq(expected = (Err(Failure.Permanent(DbErrorKind.UniqueViolation("sqlfx_test_deferred_email_key"))), Ok((0, 1)), 0), (failed, afterwards, active))
