///
/// QStatements: query ごとの文の一覧（`gen --statements` が書く JSON の中身）。文の名前・種類・書き込み先・書くカラム・
/// `ON CONFLICT DO UPDATE SET` の左辺。利用側の check（nextcms の entry-touch）が SQL のパーサを持たずに済むようにする。
///
mod TestQStatements {

    use Sqlfx.Q.QParser
    use Sqlfx.Q.QStatements

    /// .q の query ごとの文を (名前, 種類, 書き込み先, カラム, conflictSet) にする。
    def statementsOf(source: String): Result[String, List[List[(String, String, Option[String], List[String], List[String])]]] =
        QParser.parseFile(source)
            |> Result.mapErr(ToString.toString)
            |> Result.map(List.map(queryDef -> QStatements.of(queryDef) |> List.map(statement ->
                (statement#name, statement#kind, statement#target, statement#columns, statement#conflictSet))))

    ///
    ///   upsertContent     → written: insert entry_contents（カラムの並び、conflictSet）/ main: update entries [updated_at]
    ///   fillMissingField  → filled: update entry_contents [data, data_fold, updated_at] / touched: update entries / main: select
    ///   WITH の無い SELECT → main: select
    ///   DELETE             → main: delete posts
    ///   Changes の SET      → カラムに *（何を書くかは呼ぶ側が決める）
    ///   UPDATE ONLY public."t" → 書き込み先は t
    ///
    @Test
    def testStatementsTable(): Unit \ Assert =
        let others = "query a() -> many { SELECT id FROM posts }\n"
            + "query b(id: Int64) -> exec { DELETE FROM posts WHERE id = :id }\n"
            + "query c(id: Int64) -> exec with changes: Changes[posts] { UPDATE posts SET updated_at = now(), {changes} WHERE id = :id }\n"
            + "query d(id: Int64) -> exec { UPDATE ONLY public.\"posts\" SET title = 'x', views = views + 1 WHERE id = :id }\n";
        let result = statementsOf(entriesCteQueries() + others);
        Assert.assertEq(expected = Ok(List#{
            List#{
                ("written", "insert", Some("entry_contents"), List#{"project_id", "entry_id", "stage", "type_id", "data", "data_fold"}, List#{"data", "data_fold", "type_id", "updated_at"}),
                ("main", "update", Some("entries"), List#{"updated_at"}, Nil)
            },
            List#{
                ("filled", "update", Some("entry_contents"), List#{"data", "data_fold", "updated_at"}, Nil),
                ("touched", "update", Some("entries"), List#{"updated_at"}, Nil),
                ("main", "select", None, Nil, Nil)
            },
            List#{
                ("written", "insert", Some("entry_contents"), List#{"project_id", "entry_id", "stage", "type_id", "data", "data_fold"}, List#{"data", "data_fold", "type_id", "updated_at"}),
                ("touched", "update", Some("entries"), List#{"updated_at"}, Nil),
                ("main", "select", None, Nil, Nil)
            },
            List#{("main", "select", None, Nil, Nil)},
            List#{("main", "delete", Some("posts"), Nil, Nil)},
            List#{("main", "update", Some("posts"), List#{"updated_at", "*"}, Nil)},
            List#{("main", "update", Some("posts"), List#{"title", "views"}, Nil)}
        }), result)

    /// JSON: 1 query 1 line の配列。target は SELECT 以外、columns は INSERT / UPDATE、conflictSet は在る時だけ。
    @Test
    def testStatementsJson(): Unit \ Assert =
        let source = "query a(id: Int64) -> exec { DELETE FROM posts WHERE id = :id }\n"
            + "query b() -> many { WITH w AS (UPDATE posts SET title = 'x' RETURNING id) SELECT id FROM w }\n";
        let json = QParser.parseFile(source)
            |> Result.mapErr(ToString.toString)
            |> Result.map(queries -> QStatements.toJson(List.map(queryDef -> ("posts.q", queryDef), queries)));
        Assert.assertEq(expected = Ok(
            "[\n"
                + "  {\"file\": \"posts.q\", \"query\": \"a\", \"statements\": [{\"name\": \"main\", \"kind\": \"delete\", \"target\": \"posts\"}]},\n"
                + "  {\"file\": \"posts.q\", \"query\": \"b\", \"statements\": [{\"name\": \"w\", \"kind\": \"update\", \"target\": \"posts\", \"columns\": [\"title\"]}, {\"name\": \"main\", \"kind\": \"select\"}]}\n"
                + "]\n"), json)

    /// 1 つも無ければ空の配列。
    @Test
    def testStatementsJsonEmpty(): Unit \ Assert =
        Assert.assertEq(expected = "[]\n", QStatements.toJson(Nil))

}
