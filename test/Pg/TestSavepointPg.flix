use Sqlfx.Db
use Sqlfx.DbErr
use Sqlfx.DbError
use Sqlfx.DbRead
use Sqlfx.Decoder
use Sqlfx.Pool
use Sqlfx.RawSql
use Sqlfx.Sql
use Sqlfx.SqlValue
use Sqlfx.Tx

use Sqlfx.SqlValue.SqlValue
use Sqlfx.DbError.DbErrorKind
use Sqlfx.DbError.Failure
use Sqlfx.DbError.TransientKind

// Tx.withSavepoint を実 PG で: 中の失敗が外の Tx に及ばない事、印（set_config）と INSERT が戻る事、入れ子。
// 表とプールは TestPoolLeaks の物（sqlfx_test_leaks、大きさ 1 のプール）。

/// 表の name を id 順に。
def leakNames(pool: Pool.Pool): Result[Failure, List[String]] \ IO =
    RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ ->
        Sql.fetchAs(Decoder.str("name"), "SELECT name FROM sqlfx_test_leaks ORDER BY id", Nil))))

/// 5 秒の集計の代わり: statement_timeout を 50 ms にして 1 秒眠る（57014 → Transient の Timeout）。
def slowAggregate(): Int32 \ Db + RawSql =
    discard Sql.execute("SET LOCAL statement_timeout = 50", Nil);
    Sql.fetch("SELECT pg_sleep(1)", Nil) |> List.length

/// Tx の中だけ効く印を置く。
def stamp(value: String): Unit \ DbRead + RawSql =
    discard Sql.fetch("SELECT set_config('sqlfx.savepoint_test', $1, true)", List#{SqlValue.Str(value)})

/// 今の印。置いていなければ空文字。
def currentStamp(): String \ DbRead + RawSql =
    Sql.fetchOneAs(Decoder.str("v"), "SELECT current_setting('sqlfx.savepoint_test', true) AS v", Nil) |> Option.getWithDefault("")

/// (a) 中の statement_timeout（57014）は値になり、外の Tx は続きの INSERT を出して COMMIT できる。接続も返る。
///
///   BEGIN  INSERT a  SAVEPOINT agg  SET LOCAL statement_timeout  pg_sleep → 57014  ROLLBACK TO agg  INSERT b  COMMIT
///   … Ok(Err(Timeout(0)))、行は a, b
@Test
def testSavepointTimeoutInsideDoesNotBreakTx(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        insertLeakRow("a");
        let aggregate = Tx.withSavepoint("agg", slowAggregate);
        insertLeakRow("b");
        aggregate
    })));
    let names = leakNames(pool);
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(
        expected = (Ok(Err(Failure.Transient(TransientKind.Timeout(0)))), Ok(List#{"a", "b"}), 0, Ok(1)),
        (outcome, names, active, next))

/// (b) 中の set_config(..., true) は ROLLBACK TO で SAVEPOINT の前の値に戻る。SET LOCAL statement_timeout も同じく戻るので、
/// 後の pg_sleep(0.2) は切られない。
///
///   stamp outer  SAVEPOINT s [stamp inner  SET LOCAL statement_timeout 50  SELECT * FROM 無い表 → 42P01]  ROLLBACK TO s
///   current_setting → outer、pg_sleep(0.2) → 通る
@Test
def testSavepointRollsBackLocalSettings(): Unit \ {Assert, IO} =
    let pool = leakPool();
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        stamp("outer");
        let inner = Tx.withSavepoint("s", () -> {
            stamp("inner");
            discard Sql.execute("SET LOCAL statement_timeout = 50", Nil);
            Sql.fetch("SELECT * FROM sqlfx_no_such_table", Nil) |> List.length
        });
        let after = currentStamp();
        let slept = Sql.fetch("SELECT pg_sleep(0.2)", Nil) |> List.length;
        (inner |> Result.mapErr(failure -> String.startsWith(prefix = "schemaMismatch", DbError.describeFailure(failure))), after, slept)
    })));
    Pool.close(pool);
    Assert.assertEq(expected = Ok((Err(true), "outer", 1)), outcome)

/// (c) 中の INSERT は ROLLBACK TO で消え、外の INSERT は残る。中の失敗は unique 違反（制約名付きで値になる）。
///
///   INSERT outer  SAVEPOINT s [INSERT inner  INSERT inner（重複 → 23505）]  ROLLBACK TO s  COMMIT … 行は outer だけ
@Test
def testSavepointDiscardsInnerInsertKeepsOuter(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        insertLeakRow("outer");
        Tx.withSavepoint("s", () -> {
            insertLeakRow("inner");
            insertLeakRow("inner")
        })
    })));
    let names = leakNames(pool);
    Pool.close(pool);
    Assert.assertEq(
        expected = (Ok(Err(Failure.Permanent(DbErrorKind.UniqueViolation("sqlfx_test_leaks_email_key")))), Ok(List#{"outer"})),
        (outcome, names))

/// (d) 入れ子: 内側の失敗は内側の SAVEPOINT までしか戻さず、外側は続きを書いて RELEASE できる。
///
///   SAVEPOINT outer_sp [INSERT x  SAVEPOINT inner_sp [INSERT y  DbErr.other]  ROLLBACK TO inner_sp  INSERT z]  RELEASE outer_sp  COMMIT
///   … Ok(Ok(Err(other boom)))、行は x, z
@Test
def testSavepointNestedInnerFailureKeepsOuter(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () ->
        Tx.withSavepoint("outer_sp", () -> {
            insertLeakRow("x");
            let inner: Result[Failure, Unit] = Tx.withSavepoint("inner_sp", () -> {
                insertLeakRow("y");
                DbErr.other("boom")
            });
            insertLeakRow("z");
            inner |> Result.mapErr(DbError.describeFailure)
        }))));
    let names = leakNames(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(Ok(Err("other boom"))), Ok(List#{"x", "z"})), (outcome, names))

/// (d') 入れ子: 内側が RELEASE 済みでも、外側の失敗は内側の書き込みごと戻す。
///
///   INSERT before  SAVEPOINT outer_sp [SAVEPOINT inner_sp [INSERT y] RELEASE inner_sp  DbErr.other]  ROLLBACK TO outer_sp  COMMIT … 行は before だけ
@Test
def testSavepointNestedOuterFailureDiscardsReleasedInner(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        insertLeakRow("before");
        let outer: Result[Failure, Unit] = Tx.withSavepoint("outer_sp", () -> {
            discard Tx.withSavepoint("inner_sp", () -> insertLeakRow("y"));
            DbErr.other("boom")
        });
        outer |> Result.mapErr(DbError.describeFailure)
    })));
    let names = leakNames(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(Err("other boom")), Ok(List#{"before"})), (outcome, names))

/// 読むだけの Tx（READ ONLY, REPEATABLE READ）でも SAVEPOINT は張れ、中の失敗の後も外は読めて COMMIT できる。
///
///   SET TRANSACTION READ ONLY REPEATABLE READ  SAVEPOINT s [SELECT * FROM 無い表 → 42P01]  ROLLBACK TO s  SELECT 1  COMMIT
@Test
def testSavepointInReadOnlyTx(): Unit \ {Assert, IO} =
    let pool = leakPool();
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        discard Sql.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", Nil);
        let inner = Tx.withSavepoint("s", () -> Sql.fetch("SELECT * FROM sqlfx_no_such_table", Nil) |> List.length);
        let after = Sql.fetch("SELECT 1", Nil) |> List.length;
        (Result.isErr(inner), after)
    })));
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Ok((true, 1)), 0, Ok(1)), (outcome, active, next))

/// 中の失敗を値にした後に外で SQL を出さずに終えても、Tx は aborted ではないので COMMIT され `DbErr.rollback` にならない
/// （Db.attempt を Tx の中で使ったときの形（TestPoolAbortedTx）との違い）。
///
///   INSERT c  SAVEPOINT s [INSERT c（重複）]  ROLLBACK TO s  "done"  COMMIT … Ok(("done", Err)), 行は c
@Test
def testSavepointFailureDoesNotLeaveTxAborted(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let outcome = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        insertLeakRow("c");
        let duplicated = Tx.withSavepoint("s", () -> insertLeakRow("c"));
        ("done", Result.isErr(duplicated))
    })));
    let names = leakNames(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Ok(("done", true)), Ok(List#{"c"})), (outcome, names))
