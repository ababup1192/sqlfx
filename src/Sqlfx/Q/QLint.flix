///
/// 生成は止めないが、まず間違いなく意図と違う書き方を拾う（design.md §3 の「SQL はそのまま通す」方針なので、書き換えはしない）。
/// 今のところ `Option` の引数を述語の `=` の右に置いた query だけ。
///
pub mod Sqlfx.Q.QLint {

    use Sqlfx.Q.QueryDef
    use Sqlfx.Q.SqlTokens

    use Sqlfx.Q.QueryDef.Query
    use Sqlfx.Q.QueryDef.Segment

    ///
    /// 全 query の注意書き。1 件 1 行で、gen が `warning:` を付けて表示する。
    ///
    pub def warnings(queries: List[Query]): List[String] =
        List.flatMap(queryWarnings, queries)

    ///
    /// WHERE / ON / HAVING の `col = :param` に `Option` の引数を置いている所。
    /// SQL の `= NULL` は真でも偽でもなく NULL（＝その行は出ない）なので、None を渡した時だけ静かに 0 行になる。
    /// UPDATE の `SET col = :param` は NULL を書く正しい書き方なので数えない。
    /// 前に同じ引数の `:param IS NULL OR` があれば、None で絞り込みを外す書き方なので数えない。
    ///
    def queryWarnings(queryDef: Query): List[String] =
        let (_, found) = List.foldLeft(step(queryDef), ("", Nil), queryDef#body);
        List.reverse(found)

    ///
    /// (ここまでの素の SQL, 逆順の注意書き) を持って本文を 1 断片ずつ見る。
    ///
    def step(queryDef: Query, state: (String, List[String]), segment: Segment): (String, List[String]) =
        let (sqlSoFar, found) = state;
        match segment {
            case Segment.Text(text) => (sqlSoFar + text, found)
            case Segment.SlotRef(_) => (sqlSoFar, found)
            case Segment.ParamRef(name) =>
                let warned = comparesForEquality(sqlSoFar) and inPredicate(sqlSoFar) and isOptional(queryDef, name) and not guardedByIsNull(sqlSoFar, name);
                (sqlSoFar + ":${name}", if (warned) message(queryDef#name, name) :: found else found)
        }

    def message(queryName: String, paramName: String): String =
        "query ${queryName}: parameter ${paramName} is an Option, but it sits in the predicate `= :${paramName}`. "
            + "SQL's `= NULL` is never true, so passing None matches no rows "
            + "(to match NULL as well, use `IS NOT DISTINCT FROM`, or write `:${paramName} IS NULL OR col = :${paramName}`)"

    ///
    /// 素の SQL が等値の比較で終わっているか。`>=` と `<=` は範囲の比較なので数えない。
    ///
    def comparesForEquality(sql: String): Bool =
        let trimmed = String.trimRight(sql);
        String.endsWith(suffix = "<>", trimmed)
            or String.endsWith(suffix = "!=", trimmed)
            or (String.endsWith(suffix = "=", trimmed)
                and not (String.endsWith(suffix = ">=", trimmed) or String.endsWith(suffix = "<=", trimmed)))

    ///
    /// ここまでで最後に出た句が述語（WHERE / ON / HAVING）か。UPDATE の SET の中なら偽。
    ///
    def inPredicate(sql: String): Bool =
        SqlTokens.tokenize(sql)
            |> List.map(String.toUpperCase)
            |> List.filter(word -> List.memberOf(word, List#{"SET", "WHERE", "ON", "HAVING"}))
            |> List.last
            |> (clause -> match clause {
                case Some("SET") => false
                case Some(_) => true
                case None => false
            })

    ///
    /// ここまでに同じ引数の `:name IS NULL OR` があるか（大小文字と空白の違いは見ない）。
    ///
    /// WhyNot: 括弧の対応まで追って「同じ OR の中か」を見ない。守りが別の述語にある書き方は、同じ引数を 2 つの述語で
    /// 使い分ける時だけで、その時に注意を 1 つ見落としても、None で 0 行になる不具合の形（守りが無い）は拾える。
    ///
    def guardedByIsNull(sql: String, name: String): Bool =
        let words = SqlTokens.tokenize(sql) |> List.map(String.toUpperCase);
        let guard = List#{":", String.toUpperCase(name), "IS", "NULL", "OR"};
        List.exists(start -> List.take(List.length(guard), List.drop(start, words)) == guard, List.range(0, List.length(words)))

    def isOptional(queryDef: Query, name: String): Bool =
        queryDef#params |> List.exists(param -> param#name == name and param#optional)

}
