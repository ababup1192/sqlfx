use Sqlfx.Q.DdlParser
use Sqlfx.Q.QParser
use Sqlfx.Q.QResolve
use Sqlfx.Q.Schema
use Sqlfx.Q.SqlType

use Sqlfx.Q.SqlType.SqlType
use Sqlfx.Q.QResolve.ResolveError

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

/// NOT NULL の marker `!`: `::type!` の式は NOT NULL、無ければ式は NULL 可。副問い合わせの列、列参照（NULL 可の email、LEFT JOIN の相手）、
/// FILTER / OVER 付き、AS 無しの alias、`!=` を含む式（演算子は marker でない）も同じ規則。
///
///   a: count(*)::bigint! AS total            → total: Int64 NOT NULL
///   b: count(*)::bigint AS total             → total: NULL 可（marker 無し）
///   c: hits.id::text! / hits.total::bigint   → 副問い合わせの列。marker の有無で分かれる
///   d: email::text! AS email, id::bigint!    → DDL が NULL 可でも marker が勝つ / NOT NULL の列に付けても無害
///   e: LEFT JOIN の p.title::text! AS title  → JOIN で NULL 可になる列も marker で NOT NULL
///   f: FILTER (...)::bigint! / OVER ()::bigint!
///   g: count(*)::bigint! total               → AS 無しの alias
///   h: (id != 1)::boolean! AS flag           → `!=` は残り、末尾の `!` だけが marker
@Test
def testResolveNotNullMarker(): Unit \ Assert =
    let result = resolveAll(
        "query a() -> one { SELECT count(*)::bigint! AS total FROM users }\n"
            + "query b() -> one { SELECT count(*)::bigint AS total FROM users }\n"
            + "query c() -> many { SELECT hits.id::text! AS id, hits.total::bigint AS total FROM (SELECT id, count(*) OVER () AS total FROM users) AS hits }\n"
            + "query d() -> many { SELECT email::text! AS email, id::bigint! FROM users WHERE email IS NOT NULL }\n"
            + "query e() -> many { SELECT u.id, p.title::text! AS title FROM users u LEFT JOIN posts p ON p.user_id = u.id }\n"
            + "query f() -> one { SELECT count(*) FILTER (WHERE email IS NULL)::bigint! AS missing, count(*) OVER ()::bigint! AS total FROM users }\n"
            + "query g() -> one { SELECT count(*)::bigint! total FROM users }\n"
            + "query h() -> many { SELECT (id != 1)::boolean! AS flag FROM users }");
    Assert.assertEq(expected = Ok(List#{
        ("a", List#{("total", SqlType.Int64, false)}),
        ("b", List#{("total", SqlType.Int64, true)}),
        ("c", List#{("id", SqlType.Str, false), ("total", SqlType.Int64, true)}),
        ("d", List#{("email", SqlType.Str, false), ("id", SqlType.Int64, false)}),
        ("e", List#{("id", SqlType.Int64, false), ("title", SqlType.Str, false)}),
        ("f", List#{("missing", SqlType.Int64, false), ("total", SqlType.Int64, false)}),
        ("g", List#{("total", SqlType.Int64, false)}),
        ("h", List#{("flag", SqlType.Bool, false)})
    }), result)

/// marker の置き場所の誤り: cast の無い式 / 列参照だけ / cast と `!` の間に空白 / marker はあるが名前が無い。
///
///   count(*)! AS n           → MisplacedNotNullMark（cast が無い）
///   id! AS n                 → MisplacedNotNullMark（列参照には付けない）
///   count(*)::bigint ! AS n  → MisplacedNotNullMark（空白で離れた `!` は marker でない）
///   count(*)::bigint!        → UntypedColumn（式の列は名前が要る。marker を付けても同じ）
@Test
def testResolveMisplacedNotNullMarker(): Unit \ Assert =
    let errors = List#{
        "query a() -> one { SELECT count(*)! AS n FROM users }",
        "query a() -> one { SELECT id! AS n FROM users }",
        "query a() -> one { SELECT count(*)::bigint ! AS n FROM users }",
        "query a() -> one { SELECT count(*)::bigint! FROM users }"
    } |> List.map(source -> resolveAll(source) |> Result.map(List.length));
    Assert.assertEq(expected = List#{
        Err("MisplacedNotNullMark(a, count ( * ) !)"),
        Err("MisplacedNotNullMark(a, id!)"),
        Err("MisplacedNotNullMark(a, count ( * ) :: bigint !)"),
        Err("UntypedColumn(a, count ( * ))")
    }, errors)

/// 関数の table source（`unnest(...) AS v(...)`）はサブクエリと同じく opaque に飛ばす: exec の `UPDATE … FROM unnest(:a, :b)` が通り、
/// SELECT では v の列を `expr::type AS name` で書けば読める。JOIN の相手が関数でも表の列は残る。
///
///   a: UPDATE users AS u SET name = v.name FROM unnest(:ids, :names) AS v(id, name) WHERE u.id = v.id   → exec、列無し
///   b: SELECT v.n::int! AS n FROM unnest(:ns) AS v(n)                                                   → n: Int32 NOT NULL
///   c: SELECT u.id, v.n::int AS n FROM users u JOIN unnest(:ns) AS v(n) ON v.n = u.id                  → id は users の列
@Test
def testResolveFunctionSource(): Unit \ Assert =
    let result = resolveAll(
        "query a(ids: List[Int64], names: List[String]) -> exec { UPDATE users AS u SET name = v.name FROM unnest(:ids, :names) AS v(id, name) WHERE u.id = v.id }\n"
            + "query b(ns: List[Int32]) -> many { SELECT v.n::int! AS n FROM unnest(:ns) AS v(n) }\n"
            + "query c(ns: List[Int32]) -> many { SELECT u.id, v.n::int AS n FROM users u JOIN unnest(:ns) AS v(n) ON v.n = u.id }");
    Assert.assertEq(expected = Ok(List#{
        ("a", Nil),
        ("b", List#{("n", SqlType.Int32, false)}),
        ("c", List#{("id", SqlType.Int64, false), ("n", SqlType.Int32, true)})
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

/// UPSERT: ON CONFLICT DO UPDATE SET の UPDATE をテーブルの導入語と読まない。RETURNING は INSERT 先の表で解決する。
@Test
def testResolveUpsert(): Unit \ Assert =
    let source = "query u(name: String, email: String) -> one { INSERT INTO users (name, email) VALUES (:name, :email) ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name RETURNING id, name }";
    let columns = QParser.parseFile(source)
        |> Result.mapErr(ToString.toString)
        |> Result.flatMap(queries -> Result.traverse(QResolve.resolve(blogSchema()), queries) |> Result.mapErr(ToString.toString))
        |> Result.map(List.flatMap(resolved -> List.map(column -> (column#name, column#nullable), resolved#columns)));
    Assert.assertEq(expected = Ok(List#{("id", false), ("name", false)}), columns)

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
