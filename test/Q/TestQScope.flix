use QScope.ScopeError

// QScope: テナントの列（project_id）を持つ表を触る query に、その列の名前が無ければ止める。

/// entries(project_id 有り)、users(無し)、teams(project_id と org_id の 2 つ)。
def tenantSchema(): Schema.Schema =
    DdlParser.apply(
        "CREATE TABLE entries (id BIGSERIAL PRIMARY KEY, project_id BIGINT NOT NULL, title TEXT NOT NULL);"
            + "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);"
            + "CREATE TABLE teams (id BIGSERIAL PRIMARY KEY, project_id BIGINT NOT NULL, org_id BIGINT NOT NULL, name TEXT NOT NULL)",
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

// ---- 注入（`--scope <列>:<effect>`）----

def tenant(): QScope.Scope = { column = "project_id", effect = Some("Tenant") }
def org(): QScope.Scope = { column = "org_id", effect = Some("Org") }
def byProject(): (String, String) = ("projectId", "Tenant")
def byOrg(): (String, String) = ("orgId", "Org")

/// plan の結果を (query 名, (引数名, effect) の列) の列に潰す。
def planSource(scopes: List[QScope.Scope], source: String): Result[ScopeError, List[(String, List[(String, String)])]] =
    QParser.parseFile(source)
        |> Result.mapErr(_ -> ScopeError.UnknownMarkedQuery("parse"))
        |> Result.flatMap(queries -> QScope.plan(scopes, tenantSchema(), source, queries))
        |> Result.map(Map.toList)
        |> Result.map(List.map(match (name, injections) -> (name, List.map(injection -> (injection#param, injection#effect), injections))))

def byProjectId(): String = "query byProjectId(projectId: Int64) -> many { SELECT id FROM entries WHERE project_id = :projectId }\n"
def teamOfProject(): String = "query teamOfProject(projectId: Int64) -> many { SELECT id FROM teams WHERE project_id = :projectId }\n"

/// effect の無い scope（旗が `--scope project_id` だけ）は検査だけで、何も注入しない。
@Test
def testPlanWithoutEffectInjectsNothing(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok(Nil),
        planSource(List#{{ column = "project_id", effect = None }}, byProjectId()))

/// 注入するのは「列の camelCase の名前・必須の Int64・列を持つ表を触る」の全部を満たす引数だけ。
/// 別名（p）、列を持たない表（users）の同名の引数、引数の無い query（IN (...) の配列）は注入しない。
@Test
def testPlanInjectsMatchingParams(): Unit \ Assert =
    let source = byProjectId()
        + "query byAlias(p: Int64) -> many { SELECT id FROM entries WHERE project_id = :p }\n"
        + "query userById(projectId: Int64) -> one { SELECT id FROM users WHERE id = :projectId }\n"
        + "query withIds(projectId: Int64, ids: List[Int64]) -> many { SELECT id FROM entries WHERE project_id = :projectId AND id = ANY(:ids) }\n"
        + "query allOfProjects(ids: List[Int64]) -> many { SELECT id FROM entries WHERE project_id = ANY(:ids) }";
    Assert.assertEq(
        expected = Ok(List#{("byProjectId", List#{byProject()}), ("withIds", List#{byProject()})}),
        planSource(List#{tenant()}, source))

/// `// scope: explicit` は注入だけを止め、検査は受ける（列の条件が無ければ Unscoped のまま）。
@Test
def testPlanExplicitKeepsParamButChecks(): Unit \ Assert =
    let cases = List#{
        ("// scope: explicit ログインの途中で Tenant が無い\n" + byProjectId(), Ok(Nil)),
        ("// scope: explicit project_id 理由\n" + byProjectId(), Ok(Nil)),
        ("// scope: explicit 理由\nquery noScope(projectId: Int64) -> many { SELECT id FROM entries WHERE id = :projectId }", Err(ScopeError.Unscoped("noScope", "entries", "project_id")))
    };
    Assert.assertEq(
        expected = List.map(snd, cases),
        List.map(match (source, _) -> planSource(List#{tenant()}, source), cases))

/// 印の列: 書いた列にだけ効き、省けば全部の列に効く。`--scope` に無いスキーマの列を書けば MarkerColumnNotScoped。
///
///   teams は project_id と org_id を持ち、query は project_id の条件しか無い
@Test
def testPlanMarkerColumns(): Unit \ Assert =
    let cases = List#{
        ("// unscoped: org_id 組織を跨ぐ\n" + teamOfProject(), Ok(List#{("teamOfProject", List#{byProject()})})),
        ("// unscoped: 全部を跨ぐ\n" + teamOfProject(), Ok(Nil)),
        ("// unscoped: project_id 理由\n" + teamOfProject(), Err(ScopeError.Unscoped("teamOfProject", "teams", "org_id"))),
        ("// unscoped: title で引く\n" + teamOfProject(), Err(ScopeError.MarkerColumnNotScoped("teamOfProject", "title"))),
        (teamOfProject(), Err(ScopeError.Unscoped("teamOfProject", "teams", "org_id")))
    };
    Assert.assertEq(
        expected = List.map(snd, cases),
        List.map(match (source, _) -> planSource(List#{tenant(), org()}, source), cases))

/// 名前だけ合って型が違う引数は UninjectableParam（受け取った型の綴り付き）。explicit なら型は問わない。
@Test
def testPlanRejectsUninjectableParam(): Unit \ Assert =
    let withType = paramType -> "query q(projectId: ${paramType}) -> many { SELECT id FROM entries WHERE project_id = :projectId }";
    let cases = List#{
        (withType("String"), Err(ScopeError.UninjectableParam("q", "projectId", "project_id", "String"))),
        (withType("Option[Int64]"), Err(ScopeError.UninjectableParam("q", "projectId", "project_id", "Option[Int64]"))),
        (withType("Int32"), Err(ScopeError.UninjectableParam("q", "projectId", "project_id", "Int32"))),
        ("// scope: explicit 理由\n" + withType("String"), Ok(Nil))
    };
    Assert.assertEq(
        expected = List.map(snd, cases),
        List.map(match (source, _) -> planSource(List#{tenant()}, source), cases))

/// scope が複数なら列ごとに独立に判定し、両方の列を持つ表を触る query には scope の順に両方が付く。
@Test
def testPlanMultipleScopes(): Unit \ Assert =
    let source = "query team(orgId: Int64, projectId: Int64) -> many { SELECT id FROM teams WHERE project_id = :projectId AND org_id = :orgId }\n"
        + byProjectId();
    Assert.assertEq(
        expected = Ok(List#{("byProjectId", List#{byProject()}), ("team", List#{byProject(), byOrg()})}),
        planSource(List#{tenant(), org()}, source))
