///
/// QCte.split: 語の並びを「CTE の並び + 本文」に切る。WITH を CTE の始まりと見るのは `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (`
/// の形の時だけ（`timestamp with time zone`、`WITH ORDINALITY` は普通の語）。
///
mod TestQCte {

    use Sqlfx.Q.QCte
    use Sqlfx.Q.SqlTokens

    use Sqlfx.Q.QCte.CteError

    /// 切った結果を (CTE ごとの (名前, カラムの並び, 本文の語), 本文の語) にする。
    def shape(sql: String): Result[CteError, (List[(String, Option[List[String]], String)], String)] =
        QCte.split(SqlTokens.tokenize(sql)) |> Result.map(statement -> (
            statement#ctes |> List.map(cte -> (cte#name, cte#columns, List.join(" ", cte#body#words))),
            List.join(" ", statement#main#words)))

    ///
    ///   入力                                                             → 期待
    ///   SELECT 1                                                         → CTE 無し、本文は全部
    ///   WITH a AS (SELECT id FROM users) SELECT id FROM a                → [a]、本文は SELECT id FROM a
    ///   WITH a AS (SELECT 1), b AS (SELECT 2) SELECT 3                   → [a, b] の順
    ///   WITH w(x, y) AS (SELECT 1, 2) SELECT x FROM w                    → カラムの並び [x, y]
    ///   WITH a AS MATERIALIZED (…) / NOT MATERIALIZED (…)                → 読み飛ばす
    ///   WITH A AS (…) SELECT * FROM a                                    → 名前は小文字の a
    ///   SELECT now()::timestamp with time zone AS t                      → CTE 無し
    ///   SELECT v.n FROM unnest($1) WITH ORDINALITY AS v(n, i)            → CTE 無し
    ///   WITH a AS (SELECT x::timestamp with time zone AS t FROM y) …     → [a]（本文の中の with time zone は NestedWith にしない）
    ///   SELECT 'with a as (' AS w                                        → CTE 無し（リテラル）
    ///
    @Test
    def testSplitTable(): Unit \ Assert =
        let table = List#{
            ("SELECT 1", Ok((Nil, "SELECT 1"))),
            ("WITH a AS (SELECT id FROM users) SELECT id FROM a", Ok((List#{("a", None, "SELECT id FROM users")}, "SELECT id FROM a"))),
            ("WITH a AS (SELECT 1), b AS (SELECT 2) SELECT 3", Ok((List#{("a", None, "SELECT 1"), ("b", None, "SELECT 2")}, "SELECT 3"))),
            ("WITH w(x, y) AS (SELECT 1, 2) SELECT x FROM w", Ok((List#{("w", Some(List#{"x", "y"}), "SELECT 1 , 2")}, "SELECT x FROM w"))),
            ("WITH a AS MATERIALIZED (SELECT 1), b AS NOT MATERIALIZED (SELECT 2) SELECT 3", Ok((List#{("a", None, "SELECT 1"), ("b", None, "SELECT 2")}, "SELECT 3"))),
            ("WITH A AS (SELECT 1) SELECT * FROM a", Ok((List#{("a", None, "SELECT 1")}, "SELECT * FROM a"))),
            ("SELECT now()::timestamp with time zone AS t", Ok((Nil, "SELECT now ( ) :: timestamp with time zone AS t"))),
            ("SELECT v.n FROM unnest($1) WITH ORDINALITY AS v(n, i)", Ok((Nil, "SELECT v . n FROM unnest ( $1 ) WITH ORDINALITY AS v ( n , i )"))),
            ("WITH a AS (SELECT x::timestamp with time zone AS t FROM y) SELECT t FROM a", Ok((List#{("a", None, "SELECT x :: timestamp with time zone AS t FROM y")}, "SELECT t FROM a"))),
            ("SELECT 'with a as (' AS w", Ok((Nil, "SELECT 'with a as (' AS w")))
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(shape))

    ///
    ///   WITH RECURSIVE t AS (…) …                                        → RecursiveCte(t)
    ///   WITH a AS (WITH b AS (SELECT 1) SELECT * FROM b) SELECT * FROM a → NestedWith
    ///   SELECT * FROM (WITH b AS (SELECT 1) SELECT * FROM b) s           → NestedWith
    ///   WITH a AS (SELECT 1                                              → Unexpected
    ///
    @Test
    def testSplitErrors(): Unit \ Assert =
        let table = List#{
            ("WITH RECURSIVE t AS (SELECT 1 UNION SELECT 2) SELECT * FROM t", Err(CteError.RecursiveCte("t"))),
            ("WITH a AS (WITH b AS (SELECT 1) SELECT * FROM b) SELECT * FROM a", Err(CteError.NestedWith)),
            ("SELECT * FROM (WITH b AS (SELECT 1) SELECT * FROM b) s", Err(CteError.NestedWith)),
            ("WITH a AS (SELECT 1", Err(CteError.Unexpected("')' closing CTE a")))
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(shape) |> List.map(Result.map(_ -> ())) |> List.map(r -> match r { case Ok(_) => Ok(()) case Err(e) => Err(e) }))

    /// start / end は語の並び全体の中の位置。本文の語は words の [start, end) と同じ。
    @Test
    def testSplitPositions(): Unit \ Assert =
        let words = SqlTokens.tokenize("WITH a AS (SELECT 1) SELECT 2");
        let positions = QCte.split(words) |> Result.map(statement -> (
            statement#ctes |> List.map(cte -> (cte#body#start, cte#body#end)),
            (statement#main#start, statement#main#end)));
        Assert.assertEq(expected = Ok((List#{(4, 6)}, (7, 9))), positions)

}
