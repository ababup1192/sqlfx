use SqlValue.SqlValue
use Blog.RegisterFailure
use BlogForm.FormError
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

/// registerUser: RETURNING の行が返れば id。DDL の制約違反は業務エラー（RegisterErr）に翻訳される。
///
///   users_email_key（unique）→ EmailTaken / users_name_length（check）→ NameTooLong
@Test
def testRegisterUserTranslatesConstraints(): Unit \ Assert =
    let alice = { name = "alice", email = "alice@example.com" };
    let register = () -> DbError.runWithFailure(() -> Blog.runRegister(() -> Blog.registerUser(alice)));
    let inserted = DbTest.runRecording(Row.makeRows(List#{"id"}, List#{List#{SqlValue.Int64(7i64)}}), 1, register) |> fst;
    let taken = DbTest.runFailingWrite(DbErrorKind.UniqueViolation("users_email_key"), register);
    let tooLong = DbTest.runFailingWrite(DbErrorKind.CheckViolation("users_name_length"), register);
    Assert.assertEq(
        expected = (Ok(Ok(7i64)), Ok(Err(RegisterFailure.EmailTaken("alice@example.com"))), Ok(Err(RegisterFailure.NameTooLong))),
        (inserted, taken, tooLong))

/// registerUser: DDL に無い名前の制約違反（本番に手で足した物など）と、制約違反以外の DB エラーは翻訳されず、そのまま上へ流れる。
@Test
def testRegisterUserPassesOtherErrorsThrough(): Unit \ Assert =
    let register = () -> DbError.runWithFailure(() -> Blog.runRegister(() -> Blog.registerUser({ name = "alice", email = "alice@example.com" })));
    let unknownConstraint = DbTest.runFailingWrite(DbErrorKind.CheckViolation("users_added_by_hand"), register);
    let schema = DbTest.runFailingWrite(DbErrorKind.SchemaMismatch("relation users does not exist"), register);
    Assert.assertEq(
        expected = (Err(DbError.DbFailure.Permanent("checkViolation users_added_by_hand")), Err(DbError.DbFailure.Permanent("schemaMismatch relation users does not exist"))),
        (unknownConstraint, schema))

// ---- HTTP の境界の見本（BlogForm）----

/// validate は全項目の失敗を集める。name が長く email の形式でもないとき、両方が返る。
@Test
def testValidateCollectsAllErrors(): Unit \ Assert =
    let result = BlogForm.validate({ name = String.repeat(51, "a"), email = "not-an-email" }) |> Validation.toResult |> Result.mapErr(Nec.toList);
    Assert.assertEq(expected = Err(List#{FormError.NameTooLong, FormError.EmailInvalid}), result |> Result.map(_ -> ()))

/// register は検証のエラーと DB の制約違反を同じ FormError で返す。検証を通った後の unique 違反は EmailTaken。
@Test
def testRegisterUnifiesValidationAndConstraintErrors(): Unit \ Assert =
    let invalid = DbTest.runFailingWrite(DbErrorKind.Other("must not reach the DB"), () ->
        DbError.runWithFailure(() -> BlogForm.register({ name = "alice", email = "nope" })));
    let taken = DbTest.runFailingWrite(DbErrorKind.UniqueViolation("users_email_key"), () ->
        DbError.runWithFailure(() -> BlogForm.register({ name = "alice", email = "alice@example.com" })));
    Assert.assertEq(
        expected = (Ok(Err(List#{FormError.EmailInvalid})), Ok(Err(List#{FormError.EmailTaken("alice@example.com")}))),
        (invalid, taken))
