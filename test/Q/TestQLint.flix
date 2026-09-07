// QLint: 生成を止めない注意書き。Option の引数を述語の `=` の右に置いた query を拾う。

/// 1 本の .q から出る注意書きの (件数, その引数名が出るか)。
def lintCount(source: String, paramName: String): (Int32, Bool) =
    let found = QParser.parseFile(source) |> Result.map(QLint.warnings) |> Result.getWithDefault(Nil);
    (List.length(found), List.exists(warning -> String.contains(substr = "引数 ${paramName} ", warning), found))

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
