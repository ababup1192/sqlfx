use SqlValue.SqlValue
use DbError.DbFailure

// 実 PG のテストで共有する部品: 接続設定、migrations の適用、接続の開閉。

mod BlogTestSupport {

    import java.sql.Connection

    use DbError.DbFailure

    ///
    /// 接続設定。SQLFX_TEST_DSN が無ければ即 panic。
    ///
    pub def pgConfig(): Jdbc.ConnectionConfig \ IO =
        run {
            match Sys.Env.getVar("SQLFX_TEST_DSN") {
                case Some(url) => {
                    url = url,
                    user = Sys.Env.getVar("SQLFX_TEST_USER") |> Option.getWithDefault("flix"),
                    password = Sys.Env.getVar("SQLFX_TEST_PASSWORD") |> Option.getWithDefault("flix")
                }
                case None => bug!("SQLFX_TEST_DSN が無い。make test-pg で回す")
            }
        } with Sys.Env.runWithIO

    ///
    /// テーブルを消して migrations/ を Migrate.apply で当て直す。migrate 自体もここで毎回通る。
    ///
    pub def resetSchema(): Unit \ DbWrite + RawSql + IO =
        let _ = Sql.execute("DROP TABLE IF EXISTS posts, users, sqlfx_migrations CASCADE", Nil);
        let applied = run {
            Migrate.runWithResult(() -> Migrate.apply(Migrate.defaultConfig(pgConfig()), "migrations"))
        } with Fs.ReadFile.runWithFileRead
          with Fs.FileRead.runWithIO
          with Fs.DirList.runWithIO;
        match applied {
            case Ok(_) => ()
            case Err(message) => bug!("migrate failed: ${message}")
        }

    ///
    /// テーブルを作り直し、接続を開いて body を走らせ、必ず閉じる。失敗は DbFailure に落とす。
    /// テストは全部同じ users / posts を作り直すので、直列に走る前提。
    ///
    pub def withDb(body: Unit -> a \ ef): Result[DbFailure, a] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql}) + IO =
        withConn(_ -> body())

    ///
    /// withDb と同じだが、Tx を張りたいテスト向けに接続も渡す。
    ///
    pub def withConn(body: Connection -> a \ ef): Result[DbFailure, a] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql}) + IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(pgConfig(), conn -> {
            resetSchema();
            body(conn)
        })))

    ///
    /// 決まった形のテストデータ。id は BIGSERIAL なので入れた順に 1 から振られる（テーブルは毎回作り直す）。
    ///
    ///   users                                  posts
    ///   1 alice  alice@example.com  admin      1 alice "Hello"    published views 5  tags {intro, flix}
    ///   2 bob    bob@example.com    member     2 alice "Second"   published views 0  tags {}
    ///   3 carol  NULL               member     3 bob   "Draft"    draft     views 0  tags {wip}
    ///   4 dave   dave@example.com   member（退会済み）
    ///
    pub def seed(): Unit \ Db + RawSql =
        discard UsersQueries.insertUser({ name = "alice", email = "alice@example.com", role = "admin" });
        discard UsersQueries.insertUser({ name = "bob", email = "bob@example.com", role = "member" });
        discard Sql.execute("INSERT INTO users (name, email, role) VALUES ('carol', NULL, 'member')", Nil);
        discard UsersQueries.insertUser({ name = "dave", email = "dave@example.com", role = "member" });
        discard UsersQueries.softDeleteUser(4i64);
        discard PostsQueries.insertPost({ userId = 1i64, title = "Hello", body = "first post", tags = List#{"intro", "flix"} });
        discard PostsQueries.insertPost({ userId = 1i64, title = "Second", body = "", tags = Nil });
        discard PostsQueries.insertPost({ userId = 2i64, title = "Draft", body = "not yet", tags = List#{"wip"} });
        discard PostsQueries.publishPost(1i64);
        discard PostsQueries.publishPost(2i64);
        List.forEach(_ -> discard PostsQueries.addView(1i64), List.range(0, 5))

    ///
    /// テーブルを作り直し、seed を入れてから body を走らせる。
    ///
    pub def withSeed(body: Unit -> a \ ef): Result[DbFailure, a] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql}) + IO =
        withDb(() -> { seed(); body() })

    ///
    /// email から id を引く。テストの筋書きで「今入れた人」を指すために使う。
    ///
    pub def userIdOf(email: String): Option[Int64] \ DbRead =
        UsersQueries.findUserByEmail(email) |> Option.map(row -> row#id)

}
