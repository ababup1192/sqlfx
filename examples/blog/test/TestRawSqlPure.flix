use SqlValue.SqlValue

// 生 SQL 版（BlogRaw）を DB 無しで: 手書きデコーダの結果と、preload のクエリ数。

/// 手書きのデコーダで行が User になり、NULL の email は None。
@Test
def testRawFindUserDecodes(): Unit \ Assert =
    let found = DbTest.runWithRows(BlogRows.users(List#{{ id = 1i64, name = "alice", email = None }}), () -> DbError.runWithFailure(() -> BlogRaw.findUserByEmail("alice@example.com")))
        |> Result.map(Option.map(user -> (user#id, user#name, user#email)));
    Assert.assertEq(expected = Ok(Some((1i64, "alice", None))), found)

/// preload は 2 クエリ固定で、記事は投稿者ごとに id 順。
@Test
def testRawUsersWithPostsTwoQueries(): Unit \ Assert =
    let (grouped, statements) = DbTest.runRecordingWith(BlogRows.tableFor(BlogRows.sample()), 0, () -> DbError.runWithFailure(() -> BlogRaw.usersWithPosts(10i64)));
    let shape = Result.map(List.map(entry -> (entry#user#name, List.map(post -> post#title, entry#posts))), grouped);
    Assert.assertEq(
        expected = (Ok(List#{("alice", List#{"a1", "a2"}), ("bob", Nil), ("carol", List#{"c1"})}), 2),
        (shape, List.length(statements)))

/// 列が無い行を読むと DbErr.decodeError になる（型の防衛線は生 SQL でも効く）。
@Test
def testRawDecodeErrorIsDbErr(): Unit \ Assert =
    let rows = Row.makeRows(List#{"id"}, List#{List#{SqlValue.Int64(1i64)}});
    let result = DbTest.runWithRows(rows, () -> DbError.runWithFailure(() -> BlogRaw.findUserByEmail("x")));
    Assert.assertEq(expected = Err(DbError.DbFailure.Permanent("name: column 'name' is missing")), result |> Result.map(_ -> ()))
