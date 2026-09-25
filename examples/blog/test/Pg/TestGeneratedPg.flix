use Sqlfx.DbError
use Sqlfx.Fragment
use Sqlfx.Sql
use Sqlfx.Tx

use Sqlfx.Fragment.{===}
use Sqlfx.DbError.DbFailure
use Sqlfx.DbError.DbErrorKind
use Blog.RegisterFailure

// Blog のユースケース（生成コード版）を実 PostgreSQL で通しで動かす。クエリ単体は TestQueriesPg。

/// registerUser: 2 人目の同じ email は EmailTaken、他の DB エラーは境界まで上がる。
@Test
def testPgRegisterUser(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withDb(() -> (
        Blog.runRegister(() -> Blog.registerUser({ name = "alice", email = "alice@example.com" })),
        Blog.runRegister(() -> Blog.registerUser({ name = "alice2", email = "alice@example.com" })),
        UsersQueries.countUsers() |> Option.map(row -> row#total)
    ));
    Assert.assertEq(expected = Ok((Ok(1i64), Err(RegisterFailure.EmailTaken("alice@example.com")), Some(1i64))), result)

/// activeUsersNamed: prefix で前方一致、名前順。prefix が空なら全員。
///
///   alice, bob, anna → "a" で alice, anna / "" で alice, anna, bob
@Test
def testPgActiveUsersNamed(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> {
        discard Blog.runRegister(() -> Blog.registerUser({ name = "anna", email = "anna@example.com" }));
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

// ---- 制約が効いていること ----

/// name の長さの CHECK は DB が弾く。制約を消す migration が入ればここで落ちる。
/// 生成された insertUser を通しても止められないので、制約名付きの checkViolation として返る。
@Test
def testNameLengthIsEnforcedByDb(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let kind = BlogTestSupport.withDb(() ->
        DbError.runWithKind(() -> UsersQueries.insertUser({ name = String.repeat(51, "a"), email = "long@example.com", role = "member" }))
            |> Result.map(Option.map(row -> row#id)));
    Assert.assertEq(expected = Ok(Err(DbErrorKind.CheckViolation("users_name_length"))), kind)

/// NOT NULL は生成関数の引数の型が守るが、生 SQL で NULL を書けば列名付きの notNullViolation として返る。
@Test
def testNotNullIsEnforcedByDb(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let kind = BlogTestSupport.withDb(() ->
        DbError.runWithKind(() -> Sql.execute("INSERT INTO users (name, email) VALUES (NULL, 'n@example.com')", Nil)));
    Assert.assertEq(expected = Ok(Err(DbErrorKind.NotNullViolation("name"))), kind)

/// deletePostTouchingAuthor: 書き込みの CTE。記事を消し、書き手の updated_at を同じ 1 文で動かす。
///
///   users の updated_at を全部 2000-01-01 にしてから、bob（2）の記事 3 を消す
///   → 返る id は [2]、記事 3 は消え、updated_at が動いたのは bob だけ
@Test
def testPgDeletePostTouchingAuthor(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> {
        discard Sql.execute("UPDATE users SET updated_at = '2000-01-01T00:00:00Z'", Nil);
        let touched = PostsQueries.deletePostTouchingAuthor(3i64) |> List.map(row -> row#id);
        let postLeft = Sql.fetch("SELECT id FROM posts WHERE id = 3", Nil) |> List.length;
        let moved = Sql.fetchAs(Sqlfx.Decoder.int64("id"), "SELECT id FROM users WHERE updated_at > '2000-01-01T00:00:00Z' ORDER BY id", Nil);
        (touched, postLeft, moved)
    });
    Assert.assertEq(expected = Ok((List#{2i64}, 0, List#{2i64})), result)
