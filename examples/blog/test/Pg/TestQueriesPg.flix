use Fragment.{===, >>=}
use DbError.DbFailure

// 生成した各クエリを、決まったテストデータ（BlogTestSupport.seed）に対して実行し、返る行を丸ごと期待値と比べる。
// 1 テスト 1 クエリ。テーブル 1 つの物、JOIN した物、断片で絞った物、書き込み後の状態、の順。期待値は Views で名前付きに作る。

// ---- users（テーブル 1 つ） ----

/// findUser: 退会していない人は行が返り、退会済み（dave）と無い id は None。
@Test
def testFindUser(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() ->
        List#{1i64, 3i64, 4i64, 99i64} |> List.map(id -> UsersQueries.findUser(id) |> Option.map(Views.ofUserRow)));
    Assert.assertEq(expected = Ok(List#{
        Some(Views.user({ id = 1i64, name = "alice", email = Some("alice@example.com"), role = "admin" })),
        Some(Views.user({ id = 3i64, name = "carol", email = None, role = "member" })),
        None,
        None
    }), result)

/// findUserByEmail: 退会済みでも email が合えば返る（deleted_at を見ない）。
@Test
def testFindUserByEmail(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() ->
        List#{"dave@example.com", "nobody@example.com"} |> List.map(email -> UsersQueries.findUserByEmail(email) |> Option.map(Views.ofUserRow)));
    Assert.assertEq(expected = Ok(List#{
        Some(Views.user({ id = 4i64, name = "dave", email = Some("dave@example.com"), role = "member" })),
        None
    }), result)

/// searchUsers: 絞り込み無しなら退会者を除く全員が、指定した並びで返る。
///
///   名前の降順 → carol, bob, alice
@Test
def testSearchUsersAll(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() ->
        UsersQueries.searchUsers(10i64, Fragment.always(), Fragment.desc(UsersTable.name())) |> List.map(Views.ofUserRow));
    Assert.assertEq(expected = Ok(List#{
        Views.user({ id = 3i64, name = "carol", email = None, role = "member" }),
        Views.user({ id = 2i64, name = "bob", email = Some("bob@example.com"), role = "member" }),
        Views.user({ id = 1i64, name = "alice", email = Some("alice@example.com"), role = "admin" })
    }), result)

/// searchUsers: 断片で絞る。
///
///   member かつ email あり → bob だけ（carol は email が NULL、dave は退会済み）
///   LIMIT 2 で id 順 → alice, bob
///   id IN (3, 1) → alice, carol
@Test
def testSearchUsersFiltered(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> {
        let members = UsersQueries.searchUsers(10i64,
            Fragment.both(UsersTable.role() === Fragment.value("member"), Fragment.isNotNull(UsersTable.email())),
            Fragment.asc(UsersTable.id())) |> List.map(row -> row#name);
        let firstTwo = UsersQueries.searchUsers(2i64, Fragment.always(), Fragment.asc(UsersTable.id())) |> List.map(row -> row#name);
        let byIds = UsersQueries.searchUsers(10i64, Fragment.inList(UsersTable.id(), List#{3i64, 1i64}), Fragment.asc(UsersTable.id())) |> List.map(row -> row#name);
        { members = members, firstTwo = firstTwo, byIds = byIds }
    });
    Assert.assertEq(
        expected = Ok((List#{"bob"}, List#{"alice", "bob"}, List#{"alice", "carol"})),
        result |> Result.map(r -> (r#members, r#firstTwo, r#byIds)))

/// countUsers: 退会者を除いた人数。
@Test
def testCountUsers(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> UsersQueries.countUsers() |> Option.flatMap(row -> row#total));
    Assert.assertEq(expected = Ok(Some(3i64)), result)

// ---- posts（テーブル 1 つ） ----

/// postsByUsers: 渡した id の人の記事だけが id 順に、下書きも含めて返る。
///
///   [1, 2] → alice の 2 件 + bob の下書き 1 件 / [3] → carol は記事無し / [] → 無し
@Test
def testPostsByUsers(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> (
        PostsQueries.postsByUsers(List#{1i64, 2i64}) |> List.map(Views.ofPostRow),
        PostsQueries.postsByUsers(List#{3i64}) |> List.length,
        PostsQueries.postsByUsers(Nil) |> List.length
    ));
    Assert.assertEq(expected = Ok((List#{
        Views.post({ id = 1i64, userId = 1i64, title = "Hello", published = true, views = 5 }),
        Views.post({ id = 2i64, userId = 1i64, title = "Second", published = true, views = 0 }),
        Views.post({ id = 3i64, userId = 2i64, title = "Draft", published = false, views = 0 })
    }, 0, 0)), result)

/// publishedPosts: 公開済みだけを閲覧数の多い順に。断片で views を絞る。
///
///   全部 → Hello(5), Second(0)。Draft は出ない / views >= 1 → Hello だけ / LIMIT 1 → Hello
@Test
def testPublishedPosts(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> (
        PostsQueries.publishedPosts(10i64, Fragment.always()) |> List.map(row -> row#title),
        PostsQueries.publishedPosts(10i64, PostsTable.views() >>= Fragment.value(1)) |> List.map(row -> row#title),
        PostsQueries.publishedPosts(1i64, Fragment.always()) |> List.map(row -> row#title)
    ));
    Assert.assertEq(expected = Ok((List#{"Hello", "Second"}, List#{"Hello"}, List#{"Hello"})), result)

// ---- JOIN 後の形 ----

/// postWithAuthor: posts と users を JOIN した 1 行。投稿者の名前と email が記事の列に並ぶ。
///
///   記事 1 → Hello / {intro, flix} / alice / alice@example.com
///   記事 3 → Draft / {wip} / bob（下書きでも取れる）
///   記事 99 → None
@Test
def testPostWithAuthor(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() ->
        List#{1i64, 3i64, 99i64} |> List.map(id -> PostsQueries.postWithAuthor(id) |> Option.map(Views.ofPostWithAuthorRow)));
    Assert.assertEq(expected = Ok(List#{
        Some(Views.postWithAuthor({ id = 1i64, title = "Hello", body = "first post", tags = List#{"intro", "flix"}, authorName = "alice", authorEmail = Some("alice@example.com") })),
        Some(Views.postWithAuthor({ id = 3i64, title = "Draft", body = "not yet", tags = List#{"wip"}, authorName = "bob", authorEmail = Some("bob@example.com") })),
        None
    }), result)

/// usersWithPosts（2 クエリの preload）: 退会者を除く全員に、その人の記事が id 順に付く。無い人は Nil。
///
///   alice → [Hello, Second] / bob → [Draft] / carol → []
@Test
def testUsersWithPosts(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() ->
        Blog.usersWithPosts(10i64) |> List.map(entry -> (entry#user#name, List.map(post -> post#title, entry#posts))));
    Assert.assertEq(expected = Ok(List#{
        ("alice", List#{"Hello", "Second"}),
        ("bob", List#{"Draft"}),
        ("carol", Nil)
    }), result)

// ---- 書き込み後の状態 ----

/// renameUser / softDeleteUser / addView: 影響行数と、その後に読める値。
///
///   renameUser(2, "robert") → 1 行、findUser(2) は robert
///   softDeleteUser(2) → 1 行、もう一度 → 0 行、findUser(2) は None、countUsers は 2
///   addView(2) → 1 行、Second の views は 1
@Test
def testWritesThenRead(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> {
        let renamed = UsersQueries.renameUser({ id = 2i64, name = "robert" });
        let nameAfter = UsersQueries.findUser(2i64) |> Option.map(row -> row#name);
        let deleted = UsersQueries.softDeleteUser(2i64);
        let deletedAgain = UsersQueries.softDeleteUser(2i64);
        let gone = UsersQueries.findUser(2i64) |> Option.map(row -> row#name);
        let remaining = UsersQueries.countUsers() |> Option.flatMap(row -> row#total);
        let viewed = PostsQueries.addView(2i64);
        let views = PostsQueries.postsByUsers(List#{1i64}) |> List.map(row -> (row#title, row#views));
        { renamed = renamed, nameAfter = nameAfter, deleted = deleted, deletedAgain = deletedAgain, gone = gone, remaining = remaining, viewed = viewed, views = views }
    });
    Assert.assertEq(
        expected = Ok((1, Some("robert"), 1, 0, None, Some(2i64), 1, List#{("Hello", 5), ("Second", 1)})),
        result |> Result.map(r -> (r#renamed, r#nameAfter, r#deleted, r#deletedAgain, r#gone, r#remaining, r#viewed, r#views)))

/// insertPost（RETURNING）と deletePostsOfUser: 返った id で読め、消した後は無い。
///
///   insertPost(carol) → id 4 / postsByUsers([3]) は 1 件 / deletePostsOfUser(3) → 1 行 / その後 0 件
@Test
def testInsertReturningAndDelete(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withSeed(() -> {
        let inserted = PostsQueries.insertPost({ userId = 3i64, title = "Carol's first", body = "", tags = List#{"hello"} }) |> Option.map(row -> row#id);
        let seen = PostsQueries.postsByUsers(List#{3i64}) |> List.map(Views.ofPostRow);
        let deleted = PostsQueries.deletePostsOfUser(3i64);
        let after = PostsQueries.postsByUsers(List#{3i64}) |> List.length;
        (inserted, seen, deleted, after)
    });
    Assert.assertEq(expected = Ok((
        Some(4i64),
        List#{Views.post({ id = 4i64, userId = 3i64, title = "Carol's first", published = false, views = 0 })},
        1,
        0
    )), result)
