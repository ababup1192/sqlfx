use SqlValue.SqlValue
use Blog.RegisterError
use DbError.DbErrorKind

// 生成コード（.q → UsersQueries / PostsQueries）を使うユースケースを DB 無しで: preload のクエリ数と束ね方、DB エラーの業務エラーへの変換。

/// preload: 投稿者 3 人でもクエリは 2 つ、記事は投稿者ごとに id 順、無い人は Nil。
///
///   alice → [10, 11] / bob → [] / carol → [12]
@Test
def testUsersWithPostsIsTwoQueries(): Unit \ Assert =
    let (grouped, statements) = DbTest.runRecordingWith(BlogRows.tableFor(BlogRows.sample()), 0, () -> DbError.runWithFailure(() -> Blog.usersWithPosts(10i64)));
    let shape = Result.map(List.map(entry -> (entry#user#name, List.map(post -> post#id, entry#posts))), grouped);
    Assert.assertEq(
        expected = (Ok(List#{("alice", List#{10i64, 11i64}), ("bob", Nil), ("carol", List#{12i64})}), 2),
        (shape, List.length(statements)))

/// registerUser: RETURNING の行が返れば id、unique 違反は EmailTaken に変わる。
///
///   DB の代わりに「INSERT が UniqueViolation を返す」ハンドラを被せる
@Test
def testRegisterUserTurnsUniqueViolationIntoEmailTaken(): Unit \ Assert =
    let taken = run {
        DbError.runWithFailure(() -> Blog.registerUser({ name = "alice", email = "alice@example.com" }))
    } with handler SqlWrite {
        def execute(_sql, _params, resume) = resume(Ok(0))
        def executeReturning(_sql, _params, resume) = resume(Err(DbErrorKind.UniqueViolation("users_email_key")))
    };
    let inserted = DbTest.runRecording(Row.makeRows(List#{"id"}, List#{List#{SqlValue.Int64(7i64)}}), 1, () ->
        DbError.runWithFailure(() -> Blog.registerUser({ name = "alice", email = "alice@example.com" }))) |> fst;
    Assert.assertEq(expected = (Ok(Err(RegisterError.EmailTaken("alice@example.com"))), Ok(Ok(7i64))), (taken, inserted))

/// registerUser: unique 違反以外の DB エラーは業務エラーにせず、そのまま上へ流れる。
@Test
def testRegisterUserPassesOtherErrorsThrough(): Unit \ Assert =
    let result = run {
        DbError.runWithFailure(() -> Blog.registerUser({ name = "alice", email = "alice@example.com" }))
    } with handler SqlWrite {
        def execute(_sql, _params, resume) = resume(Ok(0))
        def executeReturning(_sql, _params, resume) = resume(Err(DbErrorKind.SchemaMismatch("relation users does not exist")))
    };
    Assert.assertEq(expected = Err(DbError.DbFailure.Permanent("schemaMismatch relation users does not exist")), result)
