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
        Err(ResolveError.SlotTableNotInStatement("a", "f", "posts")),
        Err(ResolveError.ChangesSlotRequiresExec("a", "c")),
        Err(ResolveError.ChangesSlotNotUpdateTarget("a", "c", "users"))
    }, errors)

// ---- CTE ----

/// blog の users / posts に、scope のカラム（project_id）を持つ entries / entry_contents を足したスキーマ。
def cteSchema(): Schema.Schema =
    DdlParser.apply(
        "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT);"
            + "CREATE TABLE posts (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL, title TEXT NOT NULL);"
            + "CREATE TABLE entries (project_id BIGINT NOT NULL, id TEXT NOT NULL, type_id BIGINT NOT NULL, version INTEGER NOT NULL, updated_at TIMESTAMPTZ NOT NULL, deleted_at TIMESTAMPTZ, PRIMARY KEY (project_id, id));"
            + "CREATE TABLE entry_contents (project_id BIGINT NOT NULL, entry_id TEXT NOT NULL, stage TEXT NOT NULL, type_id BIGINT NOT NULL, data JSONB NOT NULL, data_fold JSONB, updated_at TIMESTAMPTZ NOT NULL, PRIMARY KEY (project_id, entry_id, stage))",
        Schema.empty())
        |> Result.map(fst)
        |> Result.getWithDefault(Schema.empty())

/// .q を CTE のスキーマで解決し、(クエリ名, 列, writes) にする。
def resolveCte(source: String): Result[String, List[(String, List[(String, SqlType, Bool)], Bool)]] =
    QParser.parseFile(source)
        |> Result.mapErr(ToString.toString)
        |> Result.flatMap(queries -> Result.traverse(QResolve.resolve(cteSchema()), queries) |> Result.mapErr(ToString.toString))
        |> Result.map(List.map(resolved -> (resolved#queryDef#name, List.map(column -> (column#name, column#columnType, column#nullable), resolved#columns), resolved#writes)))

/// .q を CTE のスキーマで解決し、最初の失敗を返す。
def resolveCteError(source: String): Result[ResolveError, Int32] =
    QParser.parseFile(source)
        |> Result.mapErr(_ -> ResolveError.UnknownTable("parse", ""))
        |> Result.flatMap(queries -> Result.traverse(QResolve.resolve(cteSchema()), queries))
        |> Result.map(List.length)

/// nextcms の entries.q の 3 つ（設計の 1.3）。touch を書き込みの CTE と 1 文にした形。
def entriesCteQueries(): String =
    "query upsertContent(entryId: String, stage: String, typeId: Int64, data: Json, dataFold: Json, projectId: Int64) -> exec {\n"
        + "    WITH written AS (\n"
        + "        INSERT INTO entry_contents (project_id, entry_id, stage, type_id, data, data_fold)\n"
        + "        VALUES (:projectId, :entryId, :stage, :typeId, :data, :dataFold)\n"
        + "        ON CONFLICT (project_id, entry_id, stage) DO UPDATE\n"
        + "            SET data = EXCLUDED.data, data_fold = EXCLUDED.data_fold, type_id = EXCLUDED.type_id, updated_at = now()\n"
        + "        RETURNING entry_id\n"
        + "    )\n"
        + "    UPDATE entries SET updated_at = now()\n"
        + "    WHERE project_id = :projectId AND deleted_at IS NULL AND id = ANY(ARRAY(SELECT entry_id FROM written))\n"
        + "}\n"
        + "query fillMissingField(typeId: Int64, path: String, patch: Json, foldKey: String, foldText: String, projectId: Int64) -> many {\n"
        + "    WITH filled AS (\n"
        + "        UPDATE entry_contents\n"
        + "        SET data = data || :patch, data_fold = CASE WHEN :foldKey = '' THEN data_fold ELSE data_fold || jsonb_build_object(:foldKey, :foldText) END, updated_at = now()\n"
        + "        WHERE project_id = :projectId AND type_id = :typeId AND NOT jsonb_path_exists(data, :path::jsonpath)\n"
        + "        RETURNING entry_id\n"
        + "    ), touched AS (\n"
        + "        UPDATE entries SET updated_at = now()\n"
        + "        WHERE project_id = :projectId AND deleted_at IS NULL AND id = ANY(ARRAY(SELECT entry_id FROM filled))\n"
        + "    )\n"
        + "    SELECT entry_id FROM filled\n"
        + "}\n"
        + "query upsertContents(entryIds: List[String], stages: List[String], datas: List[String], dataFolds: List[String], typeId: Int64, projectId: Int64) -> many {\n"
        + "    WITH written AS (\n"
        + "        INSERT INTO entry_contents (project_id, entry_id, stage, type_id, data, data_fold)\n"
        + "        SELECT :projectId, v.entry_id, v.stage, :typeId, v.data::jsonb, v.data_fold::jsonb\n"
        + "        FROM (SELECT * FROM unnest(:entryIds, :stages, :datas, :dataFolds) AS u(entry_id, stage, data, data_fold)) AS v\n"
        + "        ORDER BY v.entry_id, v.stage\n"
        + "        ON CONFLICT (project_id, entry_id, stage) DO UPDATE\n"
        + "            SET data = EXCLUDED.data, data_fold = EXCLUDED.data_fold, type_id = EXCLUDED.type_id, updated_at = now()\n"
        + "        RETURNING entry_id\n"
        + "    ), touched AS (\n"
        + "        UPDATE entries SET updated_at = now()\n"
        + "        WHERE project_id = :projectId AND deleted_at IS NULL AND id = ANY(ARRAY(SELECT entry_id FROM written))\n"
        + "    )\n"
        + "    SELECT DISTINCT entry_id FROM written\n"
        + "}\n"

///
/// CTE の型付け（設計の 1.5 / 1.6）。CTE の本文には今の規則をそのまま当て、前の CTE は仮想の表として読む。
/// writes は本文か CTE のどれかが書けば true。
///
///   a: CTE の表のカラム                              → DDL の型と NULL 可否（email は NULL 可）
///   b: CTE の中の count(*)::bigint!                  → NOT NULL
///   c: 本文の a.n::bigint!                           → NOT NULL（本文の ! が勝つ）
///   d: CTE を LEFT JOIN の相手に                     → NULL 可
///   e: WITH w(x) AS (…)                              → カラムの名前は x
///   f: 後ろの CTE が前の CTE を読む                  → 前の CTE の型
///   g: 書き込みの CTE + RETURNING 無しの本文（exec） → カラム無し、writes
///   h: 書き込みの CTE を SELECT で読む               → writes（DbWrite にする）
///   i: INSERT ... SELECT ... FROM <CTE> RETURNING id → RETURNING は書き込み先（posts）だけで引く
///   j: WITH 無しの INSERT ... SELECT ... FROM users RETURNING id → 同じく posts だけ（0.5.0 は AmbiguousColumn）
///
@Test
def testResolveCteColumns(): Unit \ Assert =
    let result = resolveCte(
        "query a() -> many { WITH a AS (SELECT id, email FROM users) SELECT id, email FROM a }\n"
            + "query b() -> many { WITH a AS (SELECT count(*)::bigint! AS n FROM posts) SELECT n FROM a }\n"
            + "query c() -> many { WITH a AS (SELECT count(*)::bigint AS n FROM posts) SELECT a.n::bigint! AS n FROM a }\n"
            + "query d() -> many { WITH a AS (SELECT id FROM users) SELECT u.id, a.id AS aid FROM users u LEFT JOIN a ON a.id = u.id }\n"
            + "query e() -> many { WITH w(x) AS (SELECT id FROM users) SELECT x FROM w }\n"
            + "query f() -> many { WITH a AS (SELECT id FROM users), b AS (SELECT id FROM a) SELECT id FROM b }\n"
            + "query g(n: String, id: Int64, t: String) -> exec { WITH w AS (UPDATE users SET name = :n WHERE id = :id RETURNING id) UPDATE posts SET title = :t WHERE user_id = ANY(ARRAY(SELECT id FROM w)) }\n"
            + "query h(id: Int64) -> many { WITH w AS (DELETE FROM posts WHERE id = :id RETURNING id) SELECT id FROM w }\n"
            + "query i(n: String, t: String) -> one { WITH w AS (INSERT INTO users (name) VALUES (:n) RETURNING id) INSERT INTO posts (user_id, title) SELECT id, :t FROM w RETURNING id }\n"
            + "query j(t: String, u: Int64) -> one { INSERT INTO posts (user_id, title) SELECT id, :t FROM users WHERE id = :u RETURNING id }");
    Assert.assertEq(expected = Ok(List#{
        ("a", List#{("id", SqlType.Int64, false), ("email", SqlType.Str, true)}, false),
        ("b", List#{("n", SqlType.Int64, false)}, false),
        ("c", List#{("n", SqlType.Int64, false)}, false),
        ("d", List#{("id", SqlType.Int64, false), ("aid", SqlType.Int64, true)}, false),
        ("e", List#{("x", SqlType.Int64, false)}, false),
        ("f", List#{("id", SqlType.Int64, false)}, false),
        ("g", Nil, true),
        ("h", List#{("id", SqlType.Int64, false)}, true),
        ("i", List#{("id", SqlType.Int64, false)}, true),
        ("j", List#{("id", SqlType.Int64, false)}, true)
    }), result)

/// 設計の 1.3 の 3 つ: upsertContent は exec、fillMissingField / upsertContents は本文が SELECT でも CTE が書くので writes。
@Test
def testResolveEntriesCteQueries(): Unit \ Assert =
    Assert.assertEq(expected = Ok(List#{
        ("upsertContent", Nil, true),
        ("fillMissingField", List#{("entry_id", SqlType.Str, false)}, true),
        ("upsertContents", List#{("entry_id", SqlType.Str, false)}, true)
    }), resolveCte(entriesCteQueries()))

///
/// CTE の失敗（設計の 1.2 / 1.4 / 1.6 / 1.7）。
///
@Test
def testResolveCteErrors(): Unit \ Assert =
    let table = List#{
        ("query q() -> many { WITH b AS (SELECT id FROM a), a AS (SELECT id FROM users) SELECT id FROM b }", Err(ResolveError.UnknownTable("q", "a"))),
        ("query q() -> many { WITH a AS (SELECT 1::int AS x), a AS (SELECT 2::int AS x) SELECT x FROM a }", Err(ResolveError.DuplicateCte("q", "a"))),
        ("query q() -> many { WITH users AS (SELECT id FROM posts) SELECT id FROM users }", Err(ResolveError.CteShadowsTable("q", "users"))),
        ("query q() -> many { WITH main AS (SELECT id FROM posts) SELECT id FROM main }", Err(ResolveError.ReservedCteName("q"))),
        ("query q() -> many { WITH w(x, y) AS (SELECT id FROM users) SELECT x FROM w }", Err(ResolveError.CteColumnCount("q", "w", 2, 1))),
        ("query q(n: String) -> many { WITH w AS (UPDATE users SET name = :n) SELECT * FROM w }", Err(ResolveError.CteWithoutReturning("q", "w"))),
        ("query q(id: String) -> exec { WITH b AS (UPDATE entries SET version = version + 1 WHERE id = :id RETURNING id) UPDATE entries SET updated_at = now() WHERE id = :id }", Err(ResolveError.SameTableWrittenTwice("q", "entries", "b", "main"))),
        ("query q(id: Int64) -> exec { WITH a AS (UPDATE posts SET title = 'x' WHERE id = :id RETURNING id), b AS (DELETE FROM posts WHERE id = :id) SELECT 1 }", Err(ResolveError.SameTableWrittenTwice("q", "posts", "a", "b"))),
        ("query q(n: String) -> exec { WITH w AS (UPDATE users SET name = :n RETURNING id) SELECT id FROM w }", Err(ResolveError.UnsupportedStatement("q", "SELECT"))),
        ("query q(id: Int64) -> exec with c: Changes[users] { WITH w AS (SELECT 1::int AS x) UPDATE users SET {c} WHERE id = :id }", Err(ResolveError.ChangesSlotWithCte("q", "c"))),
        ("query q() -> many with f: Pred[posts] { WITH a AS (SELECT id FROM users WHERE {f}) SELECT id FROM a }", Err(ResolveError.SlotTableNotInStatement("q", "f", "posts"))),
        ("query q() -> many with f: Pred[users] { WITH a AS (SELECT id FROM users WHERE {f}) SELECT p.id FROM posts p }", Ok(1)),
        ("query q() -> many with f: Pred[posts] { WITH a AS (SELECT id FROM posts) SELECT u.id FROM users u WHERE {f} }", Err(ResolveError.SlotTableNotInStatement("q", "f", "posts"))),
        ("query q() -> many { WITH RECURSIVE t AS (SELECT 1::int AS n) SELECT n FROM t }", Err(ResolveError.RecursiveCte("q", "t"))),
        ("query q() -> many { WITH a AS (WITH b AS (SELECT 1::int AS n) SELECT n FROM b) SELECT n FROM a }", Err(ResolveError.NestedWith("q"))),
        ("query q() -> many { WITH v AS (VALUES (1)) SELECT * FROM v }", Err(ResolveError.UnsupportedStatement("q", "VALUES")))
    };
    Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(resolveCteError))

///
/// 失敗の 1 line（規則・受け取った値・直し方。設計の 1.9）。
///
@Test
def testDescribeCteErrors(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{
            "query q uses WITH RECURSIVE (CTE t), which the generator does not type. Put the recursive part in a SQL function and SELECT from it, or run it with RawSql",
            "query q has a WITH inside a CTE or a subquery. The generator reads only the WITH at the start of the query; move the inner CTEs up into it",
            "query q defines CTE a twice. Rename one of them",
            "CTE users in query q has the name of a table. Rename the CTE: PostgreSQL reads FROM users as the CTE but UPDATE users as the table, and the scope check needs one meaning",
            "query q names a CTE main, which is how // unscoped: points at the main statement. Rename the CTE",
            "CTE w in query q names 2 columns, but its statement returns 1. Make the list after the CTE name match the statement's columns",
            "query q reads CTE w, which writes without RETURNING, so it has no columns. Add RETURNING <columns> to CTE w",
            "query q writes table entries in both b and main. PostgreSQL applies only one of two changes to the same row in one statement (the manual, 7.8.4), so one of them would be lost without an error. Merge them into one statement, or split the query",
            "slot c of query q is Changes, which cannot be used in a query with WITH: when the changes are empty the whole statement is skipped, and so are the other CTEs' writes. Split the query",
            "slot f of query q is Pred[posts], but posts is not in the FROM of the statement that holds {f}"
        },
        List#{
            ResolveError.RecursiveCte("q", "t"),
            ResolveError.NestedWith("q"),
            ResolveError.DuplicateCte("q", "a"),
            ResolveError.CteShadowsTable("q", "users"),
            ResolveError.ReservedCteName("q"),
            ResolveError.CteColumnCount("q", "w", 2, 1),
            ResolveError.CteWithoutReturning("q", "w"),
            ResolveError.SameTableWrittenTwice("q", "entries", "b", "main"),
            ResolveError.ChangesSlotWithCte("q", "c"),
            ResolveError.SlotTableNotInStatement("q", "f", "posts")
        } |> List.map(QResolve.describe))
