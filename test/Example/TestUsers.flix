use SqlValue.SqlValue
use Row.Row

// ExampleUsers: ユースケース関数を DB 無しで検証する（層 2 / 層 3）。

/// users テーブルの結果セット。
///
///   id | name  | email
///    1 | alice | a@example.com
///    2 | bob   | NULL
def exampleUserRows(): List[Row] =
    Row.makeRows(
        List#{"id", "name", "email"},
        List#{
            List#{SqlValue.Int64(1i64), SqlValue.Str("alice"), SqlValue.Str("a@example.com")},
            List#{SqlValue.Int64(2i64), SqlValue.Str("bob"), SqlValue.Null}
        })

/// findUser は先頭行を User に組む。email の NULL は None。0 行なら None。
@Test
def testFindUser(): Unit \ Assert =
    let found = DbError.runWithFailure(() -> DbTest.runWithRows(exampleUserRows(), () -> ExampleUsers.findUser(1i64)));
    let missing = DbError.runWithFailure(() -> DbTest.runWithRows(Nil, () -> ExampleUsers.findUser(9i64)));
    Assert.assertEq(
        expected = (Ok(Some((1i64, "alice", Some("a@example.com")))), Ok(None)),
        (
            found |> Result.map(Option.map(user -> (user#id, user#name, user#email))),
            missing |> Result.map(Option.map(user -> user#id))
        ))

/// listUsers は全行を組む。
@Test
def testListUsers(): Unit \ Assert =
    let result = DbError.runWithFailure(() -> DbTest.runWithRows(exampleUserRows(), () -> ExampleUsers.listUsers()));
    Assert.assertEq(
        expected = Ok(List#{(1i64, Some("a@example.com")), (2i64, None)}),
        result |> Result.map(List.map(user -> (user#id, user#email))))

/// renameUser は UPDATE を 1 本発行し、影響行数で true / false。
@Test
def testRenameUser(): Unit \ Assert =
    let (updated, statements) = DbTest.runRecording(Nil, 1, () -> ExampleUsers.renameUser(1i64, "alice2"));
    let (missing, _) = DbTest.runRecording(Nil, 0, () -> ExampleUsers.renameUser(9i64, "x"));
    Assert.assertEq(
        expected = (true, false, List#{"UPDATE users SET name = $1 WHERE id = $2"}),
        (updated, missing, statements |> List.map(statement -> statement#sql)))

/// listUsers は何人いてもクエリ 1 本（N+1 が無い）。
@Test
def testListUsersIsOneQuery(): Unit \ Assert =
    let (_, statements) = DbTest.runRecording(exampleUserRows(), 0, () ->
        DbError.runWithFailure(() -> ExampleUsers.listUsers()));
    Assert.assertEq(expected = 1, List.length(statements))
