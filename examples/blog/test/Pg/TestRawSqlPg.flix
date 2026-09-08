use DbError.DbErrorKind
use DbError.Failure

// 生 SQL 版（BlogRaw）を実 PostgreSQL で通しで動かす。生成コード版と同じ筋書き。

/// 登録（RETURNING で id）→ 検索 → 件数。
@Test
def testRawPgRegisterAndSearch(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withDb(() -> {
        let ids = List#{{ name = "bob", email = "bob@example.com" }, { name = "alice", email = "alice@example.com" }, { name = "anna", email = "anna@example.com" }}
            |> List.map(BlogRaw.registerUser);
        (ids, BlogRaw.activeUsersNamed({ prefix = "a", limit = 10i64 }) |> List.map(user -> user#name), BlogRaw.activeUsersNamed({ prefix = "", limit = 10i64 }) |> List.length)
    });
    Assert.assertEq(expected = Ok((List#{Some(1i64), Some(2i64), Some(3i64)}, List#{"alice", "anna"}, 3)), result)

/// 記事を書いて preload で読む。配列パラメータ（ANY($1)）と text[] の往復。
@Test
def testRawPgPostsAndPreload(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withDb(() -> {
        let alice = BlogRaw.registerUser({ name = "alice", email = "alice@example.com" }) |> Option.getWithDefault(0i64);
        discard BlogRaw.registerUser({ name = "bob", email = "bob@example.com" });
        discard BlogRaw.writePost({ author = alice, title = "hello", tags = List#{"intro"} });
        discard BlogRaw.writePost({ author = alice, title = "second", tags = Nil });
        let tags = Sql.fetchAs(Decoder.strArray("tags"), "SELECT tags FROM posts ORDER BY id", Nil);
        (BlogRaw.usersWithPosts(10i64) |> List.map(entry -> (entry#user#name, List.map(post -> post#title, entry#posts))), tags, BlogRaw.countPosts())
    });
    Assert.assertEq(expected = Ok((List#{("alice", List#{"hello", "second"}), ("bob", Nil)}, List#{List#{"intro"}, Nil}, 2i64)), result)

/// 退会は Tx でまとめ、途中で失敗すれば ROLLBACK される。FK 違反は制約名付きで境界まで上がる。
///
///   Tx1: removeUser → true（記事 0、user は soft delete）
///   Tx2: 記事を書く → 無い投稿者 999 で FK 違反 → ROLLBACK → 記事は増えない
@Test
def testRawPgTxRollback(): Unit \ {Assert, IO, Fs.FileRead.FileRead} =
    let result = BlogTestSupport.withConn(conn -> {
        let alice = BlogRaw.registerUser({ name = "alice", email = "alice@example.com" }) |> Option.getWithDefault(0i64);
        discard BlogRaw.writePost({ author = alice, title = "bye", tags = Nil });
        let removed = Tx.withTx(conn, () -> BlogRaw.removeUser(alice));
        let failed = DbError.runWithFailure(() -> Tx.withTx(conn, () -> {
            discard BlogRaw.writePost({ author = alice, title = "again", tags = Nil });
            discard BlogRaw.writePost({ author = 999i64, title = "orphan", tags = Nil })
        }));
        (removed, failed, BlogRaw.countPosts())
    });
    Assert.assertEq(expected = Ok((true, Err(Failure.Permanent(DbErrorKind.ForeignKeyViolation("posts_user_id_fkey"))), 0i64)), result)
