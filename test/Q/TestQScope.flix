use Sqlfx.Q.DdlParser
use Sqlfx.Q.QParser
use Sqlfx.Q.QScope
use Sqlfx.Q.Schema

use Sqlfx.Q.QScope.ScopeError

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

/// NOT NULL の marker `!` と、FROM の関数（`unnest(...)`）は検査に影響しない: `project_id::bigint!` でも列の名前は見つかり、
/// `unnest` は表ではないので触る表に数えない（entries を触りつつ条件が無ければ止まる）。
@Test
def testScopeIgnoresMarkerAndFunctionSource(): Unit \ Assert =
    Assert.assertEq(
        expected = (Ok(()), Err("Unscoped(b, entries, project_id)")),
        (checkSource("query a(p: Int64) -> one { SELECT count(*)::bigint! AS n, project_id::bigint! AS pid FROM entries WHERE project_id = :p GROUP BY project_id }\n"
                + "query c(ids: List[Int64], titles: List[String], p: Int64) -> exec { UPDATE entries AS e SET title = v.t FROM unnest(:ids, :titles) AS v(id, t) WHERE e.id = v.id AND e.project_id = :p }"),
         checkSource("query b(ids: List[Int64], titles: List[String]) -> exec { UPDATE entries AS e SET title = v.t FROM unnest(:ids, :titles) AS v(id, t) WHERE e.id = v.id }")))

/// 列の名前が無い query は止まる。最初の違反を (クエリ名, 表, 列) で返す。
@Test
def testScopeRejectsMissingColumn(): Unit \ Assert =
    Assert.assertEq(expected = Err("Unscoped(b, entries, project_id)"), checkSource(
        "query a(p: Int64) -> many { SELECT id FROM entries WHERE project_id = :p }\n"
            + "query b(id: Int64) -> one { SELECT id FROM entries WHERE id = :id }\n"
            + "query c(id: Int64) -> exec { DELETE FROM entries WHERE id = :id }"))

/// scope のカラムの名前が `/* */` のコメントか dollar quote の中にしか無い query は止まる（0.5.0 では通っていた）。
@Test
def testScopeIgnoresCommentAndDollarQuote(): Unit \ Assert =
    Assert.assertEq(
        expected = (Err("Unscoped(a, entries, project_id)"), Err("Unscoped(b, entries, project_id)")),
        (checkSource("query a(id: Int64) -> one { SELECT id FROM entries /* project_id */ WHERE id = :id }"),
         checkSource("query b(id: Int64) -> one { SELECT id, $$project_id$$ AS note FROM entries WHERE id = :id }")))

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

// ---- WITH の無い query の触る表（USING とカンマの続き）----

/// `DELETE … USING` と `FROM a, b` の続きの表も、触る表に数える（0.5.0 では数えず素通りしていた）。
@Test
def testScopeCountsUsingAndCommaSources(): Unit \ Assert =
    Assert.assertEq(
        expected = (Err("Unscoped(a, entries, project_id)"), Err("Unscoped(b, entries, project_id)")),
        (checkSource("query a(id: Int64) -> exec { DELETE FROM users u USING entries e WHERE e.id = :id AND u.id = e.id }"),
         checkSource("query b(id: Int64) -> exec { UPDATE users u SET name = 'x' FROM users v, entries e WHERE e.id = :id AND u.id = e.id AND v.id = u.id }")))

// ---- CTE の中の各文（WITH を含む query は文ごとに R1〜R4）----

/// scope の表 entries / entry_contents と、持たない表 users。
def cteTenantSchema(): Schema.Schema =
    DdlParser.apply(
        "CREATE TABLE users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);"
            + "CREATE TABLE entries (project_id BIGINT NOT NULL, id TEXT NOT NULL, type_id BIGINT NOT NULL, version INTEGER NOT NULL, updated_at TIMESTAMPTZ NOT NULL, deleted_at TIMESTAMPTZ, PRIMARY KEY (project_id, id));"
            + "CREATE TABLE entry_contents (project_id BIGINT NOT NULL, entry_id TEXT NOT NULL, stage TEXT NOT NULL, type_id BIGINT NOT NULL, data JSONB NOT NULL, data_fold JSONB, updated_at TIMESTAMPTZ NOT NULL, PRIMARY KEY (project_id, entry_id, stage))",
        Schema.empty())
        |> Result.map(fst)
        |> Result.getWithDefault(Schema.empty())

/// --scope project_id:Tenant で plan し、注入を (query 名, 引数名) の並びにする。
def planCte(source: String): Result[ScopeError, List[(String, List[String])]] =
    QParser.parseFile(source)
        |> Result.mapErr(_ -> ScopeError.UnknownMarkedQuery("parse"))
        |> Result.flatMap(queries -> QScope.plan(List#{tenant()}, cteTenantSchema(), source, queries))
        |> Result.map(Map.toList)
        |> Result.map(List.map(match (name, injections) -> (name, List.map(injection -> injection#param, injections))))

/// 1.8 の例: CTE の DELETE に条件が無く、本文にだけ条件がある。
def goneQuery(): String =
    "query q(entryId: String, projectId: Int64) -> exec {\n"
        + "    WITH gone AS (DELETE FROM entry_contents WHERE entry_id = :entryId RETURNING entry_id)\n"
        + "    UPDATE entries SET updated_at = now() WHERE project_id = :projectId AND id = ANY(ARRAY(SELECT entry_id FROM gone))\n"
        + "}\n"

/// 設計の 1.3 の 3 つは通り、注入は projectId の 1 つ。
@Test
def testCteEntriesQueriesPass(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok(List#{("fillMissingField", List#{"projectId"}), ("upsertContent", List#{"projectId"}), ("upsertContents", List#{"projectId"})}),
        planCte(entriesCteQueries()))

///
/// WITH を含む query の各文（設計の 1.8 の表）。
///
///   #    形                                                                        期待
///   1    CTE の DELETE に条件無し、本文に条件                                      Unscoped in CTE gone
///   2    CTE に条件、本文の UPDATE entries は CTE から来た id だけ                   Unscoped in main
///   3    CTE に条件、本文は CTE だけを読む                                          通る
///   11   CTE の INSERT … SELECT project_id, … FROM entries WHERE id = :id           Unscoped(entries)（SELECT リストは数えない）
///   11'  読み元を e.project_id = :projectId で縛り、書き込み先の値は e.project_id    通る
///   12   CTE の DELETE FROM users u USING entries e WHERE e.id = :id                Unscoped(entries)
///   12'  CTE の UPDATE entry_contents c … FROM users u, entries e（カンマの続き）    Unscoped(entries)
///   13   c.project_id = e.project_id だけ（どちらも引数に縛られていない）            Unscoped(entry_contents)
///   13'  13 に e.project_id = :projectId を足す                                     通る（e が縛られ、c は結合で縛られる）
///   14   UPDATE ONLY public."entries"                                              Unscoped(entries)
///   7    外側だけ縛り、副問い合わせの entry_contents は縛らない                      Unscoped(entry_contents)
///   10   /* project_id */ にだけカラムの名前                                        Unscoped(entries)
///   R3   INSERT の書き込み先の project_id の値が引数でない（1）                     Unscoped(entry_contents)
///   SET  SET project_id = :projectId は代入で、縛りに数えない                      Unscoped(entries)
///
@Test
def testCteStatementsTable(): Unit \ Assert =
    let one = (body: String) -> "query q(id: String, entryId: String, projectId: Int64) -> many {\n${body}\n}\n";
    let table = List#{
        (goneQuery(), Err(ScopeError.UnscopedInStatement("q", "entry_contents", "project_id", "gone"))),
        (one("WITH gone AS (DELETE FROM entry_contents WHERE project_id = :projectId AND entry_id = :entryId RETURNING entry_id) UPDATE entries SET updated_at = now() WHERE id = ANY(ARRAY(SELECT entry_id FROM gone)) AND id <> :id RETURNING id"),
            Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "main"))),
        (one("WITH gone AS (DELETE FROM entry_contents WHERE project_id = :projectId AND entry_id = :entryId AND stage <> :id RETURNING entry_id) SELECT entry_id FROM gone"), Ok(List#{("q", List#{"projectId"})})),
        (one("WITH w AS (INSERT INTO entry_contents (project_id, entry_id, stage, type_id, data) SELECT project_id, id, 'draft', type_id, '{}'::jsonb FROM entries WHERE id = :entryId AND :id = :id AND :projectId = :projectId RETURNING entry_id) SELECT entry_id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "w"))),
        (one("WITH w AS (INSERT INTO entry_contents (project_id, entry_id, stage, type_id, data) SELECT e.project_id, e.id, 'draft', e.type_id, '{}'::jsonb FROM entries e WHERE e.project_id = :projectId AND e.id = :entryId AND :id = :id RETURNING entry_id) SELECT entry_id FROM w"),
            Ok(List#{("q", List#{"projectId"})})),
        (one("WITH w AS (DELETE FROM users u USING entries e WHERE e.id = :entryId AND u.name = e.id AND :id = :id AND :projectId = :projectId RETURNING u.id) SELECT id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "w"))),
        (one("WITH w AS (UPDATE entry_contents c SET stage = 'x' FROM users u, entries e WHERE c.project_id = :projectId AND e.id = c.entry_id AND u.name = :id AND c.entry_id = :entryId RETURNING c.entry_id) SELECT entry_id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "w"))),
        (one("WITH w AS (UPDATE entry_contents c SET stage = 'x' FROM entries e WHERE c.project_id = e.project_id AND e.id = :id AND c.entry_id = :entryId AND :projectId = :projectId RETURNING c.entry_id) SELECT entry_id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entry_contents", "project_id", "w"))),
        (one("WITH w AS (UPDATE entry_contents c SET stage = 'x' FROM entries e WHERE c.project_id = e.project_id AND e.project_id = :projectId AND e.id = :id AND c.entry_id = :entryId RETURNING c.entry_id) SELECT entry_id FROM w"),
            Ok(List#{("q", List#{"projectId"})})),
        (one("WITH w AS (UPDATE ONLY public.\"entries\" SET version = 1 WHERE id = :id AND :entryId = :entryId AND :projectId = :projectId RETURNING id) SELECT id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "w"))),
        (one("WITH w AS (SELECT id FROM entries WHERE project_id = :projectId AND id = :id AND id IN (SELECT entry_id FROM entry_contents WHERE stage = :entryId)) SELECT id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entry_contents", "project_id", "w"))),
        (one("WITH w AS (SELECT id FROM entries /* project_id */ WHERE id = :id AND :entryId = :entryId AND :projectId = :projectId) SELECT id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "w"))),
        (one("WITH w AS (INSERT INTO entry_contents (project_id, entry_id, stage, type_id, data) VALUES (1, :entryId, :id, 1, '{}'::jsonb) RETURNING entry_id) SELECT entry_id FROM w WHERE :projectId = :projectId"),
            Err(ScopeError.UnscopedInStatement("q", "entry_contents", "project_id", "w"))),
        (one("WITH w AS (UPDATE entries SET project_id = :projectId WHERE id = :id AND :entryId = :entryId RETURNING id) SELECT id FROM w"),
            Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "w")))
    };
    Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(planCte))

///
/// WITH を含む query の `// unscoped:` は文を名指しする（設計の 1.8 の決め 3）。
///
///   1 の形に // unscoped: in gone 理由            → 通る
///   1 の形に // unscoped: 理由（in 無し）          → UnscopedMarkerNeedsStatement
///   1 の形に // unscoped: in other 理由            → UnknownMarkedStatement
///   gone を免除し、本文の UPDATE にも条件が無い    → Unscoped in main（免除は gone だけ）
///   // scope: explicit project_id 理由           → 通る。注入無し（引数 projectId が残る）
///
@Test
def testCteMarkers(): Unit \ Assert =
    let noMainCondition =
        "query q(entryId: String) -> exec {\n"
            + "    WITH gone AS (DELETE FROM entry_contents WHERE entry_id = :entryId RETURNING entry_id)\n"
            + "    UPDATE entries SET updated_at = now() WHERE id = ANY(ARRAY(SELECT entry_id FROM gone))\n"
            + "}\n";
    let table = List#{
        ("// unscoped: in gone 掃除で全プロジェクトを跨ぐ\n" + goneQuery(), Ok(List#{("q", List#{"projectId"})})),
        ("// unscoped: 掃除で全プロジェクトを跨ぐ\n" + goneQuery(), Err(ScopeError.UnscopedMarkerNeedsStatement("q"))),
        ("// unscoped: in other 理由\n" + goneQuery(), Err(ScopeError.UnknownMarkedStatement("q", "other"))),
        ("// unscoped: in gone 理由\n" + noMainCondition, Err(ScopeError.UnscopedInStatement("q", "entries", "project_id", "main"))),
        ("// scope: explicit project_id ログインの途中\n" + String.replace(src = "WHERE entry_id = :entryId", dst = "WHERE project_id = :projectId AND entry_id = :entryId", goneQuery()), Ok(Nil))
    };
    Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(planCte))

/// 失敗の 1 line（設計の 1.9）。
@Test
def testDescribeCteScopeErrors(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{
            "query q touches entry_contents in CTE gone with no condition that ties entry_contents.project_id to a parameter. Compare it with a parameter, join it to a table that is, or write // unscoped: in gone <reason>",
            "query q touches entries in the main statement with no condition that ties entries.project_id to a parameter. Compare it with a parameter, join it to a table that is, or write // unscoped: in main <reason>",
            "query q has WITH, so // unscoped: must name the statements it exempts: // unscoped: in <CTE name or main> <reason>",
            "// unscoped: of query q names other, which is neither a CTE of the query nor main"
        },
        List#{
            ScopeError.UnscopedInStatement("q", "entry_contents", "project_id", "gone"),
            ScopeError.UnscopedInStatement("q", "entries", "project_id", "main"),
            ScopeError.UnscopedMarkerNeedsStatement("q"),
            ScopeError.UnknownMarkedStatement("q", "other")
        } |> List.map(QScope.describe))
