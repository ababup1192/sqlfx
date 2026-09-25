use Sqlfx.Q.QLint
use Sqlfx.Q.QParser
use Sqlfx.Timestamp

// QLint: 生成を止めない注意書き。Option の引数を述語の `=` の右に置いた query を拾う。

/// 1 本の .q から出る注意書きの (件数, その引数名が出るか)。
def lintCount(source: String, paramName: String): (Int32, Bool) =
    let found = QParser.parseFile(source) |> Result.map(QLint.warnings) |> Result.getWithDefault(Nil);
    (List.length(found), List.exists(warning -> String.contains(substr = "parameter ${paramName} ", warning), found))

/// WHERE / ON の `= :param` と `<> :param` に Option を置いたら注意する。
///
///   WHERE role = :role   → 注意（None なら 1 行も引けない）
///   ON u.role = :role    → 注意
///   WHERE role <> :role  → 注意
@Test
def testWarnsOnEqualityInPredicate(): Unit \ Assert =
    Assert.assertEq(
        expected = List.repeat(3, (1, true)),
        List#{
            lintCount("query a(role: Option[String]) -> many { SELECT id FROM users WHERE role = :role }", "role"),
            lintCount("query b(role: Option[String]) -> many { SELECT p.id FROM posts AS p JOIN users AS u ON u.role = :role }", "role"),
            lintCount("query c(role: Option[String]) -> many { SELECT id FROM users WHERE role <> :role }", "role")
        })

/// 注意しない書き方: SET の代入、素の型の引数、`IS NOT DISTINCT FROM`、`>=` の範囲。
///
///   SET role = :role                      → NULL を書く正しい書き方
///   WHERE role = :role（Option でない）   → NULL を渡せないので起きない
///   WHERE role IS NOT DISTINCT FROM :role → NULL も引ける書き方
///   WHERE created_at >= :since            → 範囲の比較
@Test
def testNoWarningForAssignmentsAndSafeForms(): Unit \ Assert =
    Assert.assertEq(
        expected = List.repeat(4, (0, false)),
        List#{
            lintCount("query a(id: Int64, role: Option[String]) -> exec { UPDATE users SET role = :role WHERE id = :id }", "role"),
            lintCount("query b(role: String) -> many { SELECT id FROM users WHERE role = :role }", "role"),
            lintCount("query c(role: Option[String]) -> many { SELECT id FROM users WHERE role IS NOT DISTINCT FROM :role }", "role"),
            lintCount("query d(since: Option[Timestamp]) -> many { SELECT id FROM users WHERE created_at >= :since }", "since")
        })

/// `:param IS NULL OR col = :param` は None なら絞り込みを外す書き方なので注意しない。守っているのが別の引数なら注意する。
///
///   WHERE (:role IS NULL OR role = :role)   → 注意しない（注意書きが勧めている形）
///   WHERE (:other IS NULL OR role = :role)  → 注意（role の None は守られていない）
@Test
def testNoWarningWhenGuardedByIsNull(): Unit \ Assert =
    Assert.assertEq(
        expected = ((0, false), (1, true)),
        (lintCount("query a(role: Option[String]) -> many { SELECT id FROM users WHERE (:role IS NULL OR role = :role) }", "role"),
         lintCount("query b(role: Option[String], other: Option[String]) -> many { SELECT id FROM users WHERE (:other IS NULL OR role = :role) }", "role")))

/// 本文から読まれない SELECT の CTE は警告する（PG はそれを実行しない）。読まれない書き込みの CTE は警告しない（PG は実行する）。
///
///   WITH a AS (SELECT …) SELECT 2           → 警告（a を誰も読まない）
///   WITH a AS (SELECT …) SELECT x FROM a    → 無し
///   WITH w AS (UPDATE …) SELECT 1           → 無し（書き込みの CTE）
///   WITH a AS (SELECT …), b AS (SELECT … FROM a) SELECT … FROM b → 無し（a は b が読む）
@Test
def testUnusedSelectCte(): Unit \ Assert =
    let warningsOf = source -> QParser.parseFile(source) |> Result.map(QLint.warnings) |> Result.getWithDefault(List#{"parse error"});
    Assert.assertEq(
        expected = List#{
            List#{"query a: CTE a is a SELECT that nothing reads. PostgreSQL does not run it; read it in FROM or remove it"},
            Nil,
            Nil,
            Nil
        },
        List#{
            warningsOf("query a() -> many { WITH a AS (SELECT 1::int AS x) SELECT 2::int AS y }"),
            warningsOf("query b() -> many { WITH a AS (SELECT 1::int AS x) SELECT x FROM a }"),
            warningsOf("query c(n: String) -> many { WITH w AS (UPDATE users SET name = :n RETURNING id) SELECT 1::int AS y }"),
            warningsOf("query d() -> many { WITH a AS (SELECT 1::int AS x), b AS (SELECT x FROM a) SELECT x FROM b }")
        })
