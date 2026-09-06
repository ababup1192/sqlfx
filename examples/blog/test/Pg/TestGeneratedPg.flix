use Fragment.{===}
use DbError.DbFailure
use Blog.RegisterError

// Blog のユースケース（生成コード版）を実 PostgreSQL で通しで動かす。クエリ単体は TestQueriesPg。

/// registerUser: 2 人目の同じ email は EmailTaken、他の DB エラーは境界まで上がる。
@Test
def testPgRegisterUser(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withDb(() -> (
        Blog.registerUser({ name = "alice", email = "alice@example.com" }),
        Blog.registerUser({ name = "alice2", email = "alice@example.com" }),
        UsersQueries.countUsers() |> Option.flatMap(row -> row#total)
    ));
    Assert.assertEq(expected = Ok((Ok(1i64), Err(RegisterError.EmailTaken("alice@example.com")), Some(1i64))), result)

/// activeUsersNamed: prefix で前方一致、名前順。prefix が空なら全員。
///
///   alice, bob, anna → "a" で alice, anna / "" で alice, anna, bob
@Test
def testPgActiveUsersNamed(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> {
        discard Blog.registerUser({ name = "anna", email = "anna@example.com" });
        (Blog.activeUsersNamed({ prefix = "a", limit = 10i64 }) |> List.map(row -> row#name), Blog.activeUsersNamed({ prefix = "", limit = 10i64 }) |> List.map(row -> row#name))
    });
    Assert.assertEq(expected = Ok((List#{"alice", "anna"}, List#{"alice", "anna", "bob", "carol"})), result)

/// publishNewPost: RETURNING の id で公開まで済み、JOIN で投稿者ごと読める。
@Test
def testPgPublishNewPost(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> {
        let id = Blog.publishNewPost({ author = 3i64, title = "Carol says hi", body = "", tags = List#{"hello"} });
        let seen = id |> Option.flatMap(PostsQueries.postWithAuthor) |> Option.map(Views.ofPostWithAuthorRow);
        let published = PostsQueries.publishedPosts(10i64, PostsTable.userId() === Fragment.value(3i64)) |> List.map(row -> row#title);
        (id, seen, published)
    });
    Assert.assertEq(expected = Ok((
        Some(4i64),
        Some(Views.postWithAuthor({ id = 4i64, title = "Carol says hi", body = "", tags = List#{"hello"}, authorName = "carol", authorEmail = None })),
        List#{"Carol says hi"}
    )), result)

/// removeUser は Tx の中で記事削除と soft delete をまとめる。退会後は findUser が None、2 回目は false。
@Test
def testPgRemoveUserInTx(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withConn(conn -> {
        BlogTestSupport.seed();
        let removed = Tx.withTx(conn, () -> Blog.removeUser(1i64));
        let again = Tx.withTx(conn, () -> Blog.removeUser(1i64));
        let after = (UsersQueries.findUser(1i64) |> Option.map(row -> row#name), PostsQueries.postsByUsers(List#{1i64}) |> List.length);
        (removed, again, after)
    });
    Assert.assertEq(expected = Ok((true, false, (None, 0))), result)
