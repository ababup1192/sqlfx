use SqlType.SqlType
use QResolve.ResolveError

// QResolve: .q の SQL を机上のスキーマに当てて、結果の列を決める。

/// users(id, name, email?) と posts(id, user_id, title) のスキーマ。
def blogSchema(): Schema.Schema =
    DdlParser.apply(
        "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT);"
            + "CREATE TABLE posts (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL, title TEXT NOT NULL)",
        Schema.empty())
        |> Result.map(fst)
        |> Result.getWithDefault(Schema.empty())

/// .q を読んで解決し、(クエリ名, 列の (名前, 型, NULL 可否)) にする。
def resolveAll(source: String): Result[String, List[(String, List[(String, SqlType, Bool)])]] =
    QParser.parseFile(source)
        |> Result.mapErr(ToString.toString)
        |> Result.flatMap(queries -> Result.traverse(QResolve.resolve(blogSchema()), queries) |> Result.mapErr(ToString.toString))
        |> Result.map(List.map(resolved -> (resolved#queryDef#name, List.map(column -> (column#name, column#columnType, column#nullable), resolved#columns))))

/// 列名 / alias 付き / `*` / JOIN の修飾 / キャスト式 / LEFT・RIGHT・FULL JOIN の NULL 化 / exec は列無し / RETURNING / `--` コメント。
@Test
def testResolveShapes(): Unit \ Assert =
    let result = resolveAll(
        "query a(id: Int64) -> one { SELECT id, name AS display, email FROM users WHERE id = :id }\n"
            + "query b() -> many { SELECT * FROM posts }\n"
            + "query c() -> many { SELECT p.id, u.name AS author FROM posts p JOIN users u ON u.id = p.user_id }\n"
            + "query d() -> one { SELECT count(*)::bigint AS total, id::text FROM users }\n"
            + "query e() -> many { SELECT u.id, p.title FROM users u LEFT JOIN posts p ON p.user_id = u.id }\n"
            + "query f(id: Int64) -> exec { DELETE FROM posts WHERE id = :id }\n"
            + "query g() -> many { SELECT u.id, p.title FROM users u LEFT OUTER JOIN posts p ON p.user_id = u.id }\n"
            + "query h() -> many { SELECT u.id, p.title FROM users u RIGHT JOIN posts p ON p.user_id = u.id }\n"
            + "query i() -> many { SELECT u.id, p.title FROM users u FULL OUTER JOIN posts p ON p.user_id = u.id }\n"
            + "query j(name: String) -> one { INSERT INTO users (name) VALUES (:name) RETURNING id, email }\n"
            + "query k() -> many {\n  -- don't count the deleted ones (from users)\n  SELECT id FROM users\n}");
    Assert.assertEq(expected = Ok(List#{
        ("a", List#{("id", SqlType.Int64, false), ("display", SqlType.Str, false), ("email", SqlType.Str, true)}),
        ("b", List#{("id", SqlType.Int64, false), ("user_id", SqlType.Int64, false), ("title", SqlType.Str, false)}),
        ("c", List#{("id", SqlType.Int64, false), ("author", SqlType.Str, false)}),
        ("d", List#{("total", SqlType.Int64, true), ("id", SqlType.Str, false)}),
        ("e", List#{("id", SqlType.Int64, false), ("title", SqlType.Str, true)}),
        ("f", Nil),
        ("g", List#{("id", SqlType.Int64, false), ("title", SqlType.Str, true)}),
        ("h", List#{("id", SqlType.Int64, true), ("title", SqlType.Str, false)}),
        ("i", List#{("id", SqlType.Int64, true), ("title", SqlType.Str, true)}),
        ("j", List#{("id", SqlType.Int64, false), ("email", SqlType.Str, true)}),
        ("k", List#{("id", SqlType.Int64, false)})
    }), result)

/// 読みか書きかは文の種類で決まる。RETURNING 付きの書き込みは列を返すが書き込み扱い。
@Test
def testResolveWrites(): Unit \ Assert =
    let writes = QParser.parseFile(
            "query a() -> many { SELECT id FROM users }\n"
                + "query b() -> exec { UPDATE users SET name = 'x' }\n"
                + "query c() -> one { DELETE FROM users WHERE id = 1 RETURNING id }")
        |> Result.mapErr(_ -> ResolveError.UnknownTable("parse", ""))
        |> Result.flatMap(queries -> Result.traverse(QResolve.resolve(blogSchema()), queries))
        |> Result.map(List.map(resolved -> resolved#writes));
    Assert.assertEq(expected = Ok(List#{false, true, true}), writes)

/// 解決の失敗: 無いテーブル / 無い列 / 曖昧な列 / 型の無い式 / one に RETURNING 無しの UPDATE / exec に RETURNING / keyed が結果に無い / slot のテーブルが FROM に無い
/// / Changes が exec 以外 / Changes のテーブルが UPDATE の対象でない（FROM にはある）。
@Test
def testResolveErrors(): Unit \ Assert =
    let errors = List#{
        "query a() -> many { SELECT id FROM nope }",
        "query a() -> many { SELECT nope FROM users }",
        "query a() -> many { SELECT id FROM users, posts }",
        "query a() -> many { SELECT count(*) AS n FROM users }",
        "query a() -> one { UPDATE users SET name = 'x' }",
        "query a() -> exec { UPDATE users SET name = 'x' RETURNING id }",
        "query a() -> many keyed(user_id) { SELECT id FROM posts }",
        "query a() -> many with f: Pred[posts] { SELECT id FROM users WHERE {f} }",
        "query a() -> one with c: Changes[users] { UPDATE users SET {c} RETURNING id }",
        "query a() -> exec with c: Changes[users] { UPDATE posts SET {c} FROM users WHERE users.id = posts.user_id }"
    } |> List.map(source -> QParser.parseFile(source) |> Result.mapErr(_ -> ResolveError.UnknownTable("parse", "")) |> Result.flatMap(queries -> Result.traverse(QResolve.resolve(blogSchema()), queries)) |> Result.map(List.length));
    Assert.assertEq(expected = List#{
        Err(ResolveError.UnknownTable("a", "nope")),
        Err(ResolveError.UnknownColumn("a", "nope")),
        Err(ResolveError.AmbiguousColumn("a", "id")),
        Err(ResolveError.UntypedColumn("a", "count ( * )")),
        Err(ResolveError.UnsupportedStatement("a", "UPDATE")),
        Err(ResolveError.UnsupportedStatement("a", "UPDATE")),
        Err(ResolveError.KeyedNotInResult("a", "user_id")),
        Err(ResolveError.SlotTableNotInFrom("a", "f", "posts")),
        Err(ResolveError.ChangesSlotRequiresExec("a", "c")),
        Err(ResolveError.ChangesSlotNotUpdateTarget("a", "c", "users"))
    }, errors)
