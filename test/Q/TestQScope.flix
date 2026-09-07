use QScope.ScopeError

// QScope: テナントの列（project_id）を持つ表を触る query に、その列の名前が無ければ止める。

/// entries(project_id 有り) と users(無し)。
def tenantSchema(): Schema.Schema =
    DdlParser.apply(
        "CREATE TABLE entries (id BIGSERIAL PRIMARY KEY, project_id BIGINT NOT NULL, title TEXT NOT NULL);"
            + "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL)",
        Schema.empty())
        |> Result.map(fst)
        |> Result.getWithDefault(Schema.empty())

def checkSource(source: String): Result[String, Unit] =
    QParser.parseFile(source)
        |> Result.mapErr(ToString.toString)
        |> Result.flatMap(queries -> QScope.check("project_id", tenantSchema(), source, queries) |> Result.mapErr(ToString.toString))

/// 条件付きの SELECT / INSERT の列 / UPDATE / DELETE、列を持たない表、修飾付き（e.project_id）は通る。
@Test
def testScopeAccepts(): Unit \ Assert =
    Assert.assertEq(expected = Ok(()), checkSource(
        "query a(p: Int64) -> many { SELECT id FROM entries WHERE project_id = :p }\n"
            + "query b(p: Int64, t: String) -> one { INSERT INTO entries (project_id, title) VALUES (:p, :t) RETURNING id }\n"
            + "query c(p: Int64, id: Int64) -> exec { UPDATE entries SET title = 'x' WHERE id = :id AND project_id = :p }\n"
            + "query d(p: Int64) -> exec { DELETE FROM entries WHERE project_id = :p }\n"
            + "query e() -> many { SELECT id FROM users }\n"
            + "query f(p: Int64) -> many { SELECT e.id FROM users AS u JOIN entries AS e ON e.project_id = :p }"))

/// 列の名前が無い query は止まる。最初の違反を (クエリ名, 表, 列) で返す。
@Test
def testScopeRejectsMissingColumn(): Unit \ Assert =
    Assert.assertEq(expected = Err("Unscoped(b, entries, project_id)"), checkSource(
        "query a(p: Int64) -> many { SELECT id FROM entries WHERE project_id = :p }\n"
            + "query b(id: Int64) -> one { SELECT id FROM entries WHERE id = :id }\n"
            + "query c(id: Int64) -> exec { DELETE FROM entries WHERE id = :id }"))

/// `// unscoped: 理由` を直前に書いた query は通る。印は直後の query にだけ効く。
@Test
def testScopeUnscopedMarker(): Unit \ Assert =
    let source =
        "// unscoped: hash で引いてから呼ぶ側が照合する\n"
            + "query byHash(h: String) -> one { SELECT id, project_id FROM entries WHERE title = :h }\n"
            + "// 普通のコメント\n"
            + "query other(id: Int64) -> one { SELECT id FROM entries WHERE id = :id }";
    Assert.assertEq(expected = (List#{"byHash"}, Err("Unscoped(other, entries, project_id)")), (QScope.unscopedNames(source), checkSource(source)))
