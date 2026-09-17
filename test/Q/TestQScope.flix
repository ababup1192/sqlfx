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

// ---- `// unscoped:` の印 ----

def byHash(): String = "query byHash(h: String) -> one { SELECT id FROM entries WHERE title = :h }\n"
def other(): String = "query other(id: Int64) -> one { SELECT id FROM entries WHERE id = :id }"

/// 印が効く並び（直後 / コメント 1 行を挟む / 空行を挟む）では byHash が免除され、印の無い other だけが止まる。
/// 印は直後の query にだけ効き、その後のコメントで次の query には及ばない。
@Test
def testScopeMarkerReachesNextQuery(): Unit \ Assert =
    let cases = List#{
        ("// unscoped: hash で引く\n" + byHash() + "// 普通のコメント\n" + other(),
            (Ok(List#{"byHash"}), Err("Unscoped(other, entries, project_id)"))),
        ("// unscoped: hash で引く\n// 呼ぶ側が照合する\n" + byHash() + other(),
            (Ok(List#{"byHash"}), Err("Unscoped(other, entries, project_id)"))),
        ("// unscoped: hash で引く\n\n" + byHash() + other(),
            (Ok(List#{"byHash"}), Err("Unscoped(other, entries, project_id)")))
    };
    Assert.assertEq(
        expected = List.map(snd, cases),
        List.map(match (source, _) -> (QScope.markedNames(prefix = "// unscoped:", source), checkSource(source)), cases))

/// 印の後に query が来ない（別の行 / ファイル末尾 / 印の重なり）と、印の行番号を持つ DanglingMarker で止まる。
@Test
def testScopeMarkerDangling(): Unit \ Assert =
    let cases = List#{
        ("// unscoped: 理由\nfragment x { id }\n" + byHash(), Err(ScopeError.DanglingMarker(1))),
        (byHash() + "// unscoped: 理由\n", Err(ScopeError.DanglingMarker(2))),
        ("// unscoped: 理由\n// unscoped: 理由 2\n" + byHash(), Err(ScopeError.DanglingMarker(1)))
    };
    Assert.assertEq(
        expected = List.map(snd, cases),
        List.map(match (source, _) -> QScope.markedNames(prefix = "// unscoped:", source), cases))

/// 印が指す名前が query の一覧に無ければ UnknownMarkedQuery で止まる（印の名前と query の名前の食い違い）。
@Test
def testScopeMarkerUnknownQuery(): Unit \ Assert =
    let marked = "// unscoped: 理由\nquery byHsh(h: String) -> one { SELECT id FROM entries WHERE title = :h }";
    let queries = QParser.parseFile(byHash()) |> Result.getWithDefault(Nil);
    Assert.assertEq(
        expected = Err(ScopeError.UnknownMarkedQuery("byHsh")),
        QScope.check("project_id", tenantSchema(), marked, queries))
