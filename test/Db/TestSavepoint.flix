use DbError.DbErrorKind
use DbError.Failure
use Savepoint.Command

// Savepoint: 名前の検査と SQL 化（純粋）。Tx.withSavepoint の SQL の並び（DbTest.runRecording で見る）。

/// 名前は `^[a-z_][a-z0-9_]*$` で 63 文字まで。SQL の文面に入るのはこれだけなので、それ以外は全部落とす。
///
///   入力            → 期待
///   "s"             → true
///   "agg_1"         → true
///   "_x"            → true
///   ""              → false（空）
///   "1s"            → false（数字始まり）
///   "Agg"           → false（大文字）
///   "s p"           → false（空白）
///   "s;"            → false（記号）
///   "s\"x"          → false（引用符）
///   "sé"            → false（ASCII 以外）
///   63 文字の "a"    → true
///   64 文字の "a"    → false（PG が黙って切り詰めるので、別名が同じ名前に潰れる）
@Test
def testSavepointNameIsIdentifier(): Unit \ Assert =
    let table = List#{
        ("s", true),
        ("agg_1", true),
        ("_x", true),
        ("", false),
        ("1s", false),
        ("Agg", false),
        ("s p", false),
        ("s;", false),
        ("s\"x", false),
        ("sé", false),
        (String.repeat(63, "a"), true),
        (String.repeat(64, "a"), false)
    };
    Assert.assertEq(
        expected = table |> List.map(snd),
        table |> List.map(fst) |> List.map(Savepoint.isValidName))

/// Command は 3 つの文に写る。
@Test
def testSavepointCommandToSql(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{"SAVEPOINT agg", "RELEASE SAVEPOINT agg", "ROLLBACK TO SAVEPOINT agg"},
        List#{Command.Savepoint("agg"), Command.Release("agg"), Command.RollbackTo("agg")} |> List.map(Savepoint.toSql))

// ---- Tx.withSavepoint の SQL の並び ----

/// 発行した SQL の文面だけ。
def sqlOf(statements: List[Row.Statement]): List[String] =
    statements |> List.map(statement -> statement#sql)

/// 成功なら SAVEPOINT → thunk の SQL → RELEASE の順で、値は Ok。
@Test
def testWithSavepointReleasesOnSuccess(): Unit \ Assert =
    let (outcome, statements) = DbTest.runRecording(Nil, 1, () -> DbError.runWithFailure(() -> RawSql.runWithAllow(() ->
        Tx.withSavepoint("agg", () -> Sql.execute("INSERT INTO t VALUES (1)", Nil)))));
    Assert.assertEq(
        expected = (Ok(Ok(1)), List#{"SAVEPOINT agg", "INSERT INTO t VALUES (1)", "RELEASE SAVEPOINT agg"}),
        (outcome, sqlOf(statements)))

/// thunk が DbErr を投げたら ROLLBACK TO で戻し、その失敗を値で返す。外の Tx には失敗が飛ばない（外側の runWithFailure は Ok）。
@Test
def testWithSavepointRollsBackToOnFailure(): Unit \ Assert =
    let (outcome, statements): (Result[Failure, Result[Failure, Unit]], List[Row.Statement]) = DbTest.runRecording(Nil, 1, () -> DbError.runWithFailure(() ->
        Tx.withSavepoint("agg", () -> DbErr.other("boom"))));
    Assert.assertEq(
        expected = (Ok(Err(Failure.Permanent(DbErrorKind.Other("boom")))), List#{"SAVEPOINT agg", "ROLLBACK TO SAVEPOINT agg"}),
        (outcome, sqlOf(statements)))

/// 一時障害（statement_timeout のような Transient）も値になり、外の Tx の再試行には乗らない。
@Test
def testWithSavepointKeepsTransientAsValue(): Unit \ Assert =
    let (outcome, statements): (Result[Failure, Result[Failure, Unit]], List[Row.Statement]) = DbTest.runRecording(Nil, 1, () -> DbError.runWithFailure(() ->
        Tx.withSavepoint("agg", () -> TransientDbErr.timeout(5000))));
    Assert.assertEq(
        expected = (Ok(Err(Failure.Transient(DbError.TransientKind.Timeout(5000)))), List#{"SAVEPOINT agg", "ROLLBACK TO SAVEPOINT agg"}),
        (outcome, sqlOf(statements)))

/// 名前が不正なら SQL を 1 本も出さずに Err（thunk も呼ばない）。
@Test
def testWithSavepointRejectsBadNameWithoutSql(): Unit \ Assert =
    let (outcome, statements) = DbTest.runRecording(Nil, 1, () -> DbError.runWithFailure(() -> RawSql.runWithAllow(() ->
        Tx.withSavepoint("agg; DROP TABLE t", () -> Sql.execute("INSERT INTO t VALUES (1)", Nil)))));
    Assert.assertEq(
        expected = (Ok(Err(Failure.Permanent(DbErrorKind.Other("invalid savepoint name: agg; DROP TABLE t (expected ^[a-z_][a-z0-9_]*$, at most 63 chars)")))), Nil),
        (outcome, sqlOf(statements)))

/// SAVEPOINT 自体の失敗（handler が Err を返す）は値にせず、外の Tx へ DbErr として投げる。
@Test
def testWithSavepointRaisesWhenSavepointItselfFails(): Unit \ Assert =
    let outcome = DbError.runWithFailure(() ->
        run {
            Tx.withSavepoint("agg", () -> 1)
        } with handler SqlSavepoint {
            def control(_command, resume) = resume(Err(DbErrorKind.Other("25P02")))
        });
    Assert.assertEq(expected = Err(Failure.Permanent(DbErrorKind.Other("25P02"))), outcome)
