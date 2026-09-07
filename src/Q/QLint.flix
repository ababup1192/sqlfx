///
/// 生成は止めないが、まず間違いなく意図と違う書き方を拾う（design.md §3 の「SQL はそのまま通す」方針なので、書き換えはしない）。
/// 今のところ `Option` の引数を述語の `=` の右に置いた query だけ。
///
mod QLint {

    use QueryDef.Query
    use QueryDef.Segment

    ///
    /// 全 query の注意書き。1 件 1 行で、gen が `warning:` を付けて表示する。
    ///
    pub def warnings(queries: List[Query]): List[String] =
        List.flatMap(queryWarnings, queries)

    ///
    /// WHERE / ON / HAVING の `col = :param` に `Option` の引数を置いている所。
    /// SQL の `= NULL` は真でも偽でもなく NULL（＝その行は出ない）なので、None を渡した時だけ静かに 0 行になる。
    /// UPDATE の `SET col = :param` は NULL を書く正しい書き方なので数えない。
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
                if (comparesForEquality(sqlSoFar) and inPredicate(sqlSoFar) and isOptional(queryDef, name))
                    (sqlSoFar, message(queryDef#name, name) :: found)
                else
                    (sqlSoFar, found)
        }

    def message(queryName: String, paramName: String): String =
        "query ${queryName}: 引数 ${paramName} は Option だが、述語の `= :${paramName}` に置いている。"
            + "SQL の `= NULL` は真にならないので、None を渡すと 1 行も引けない"
            + "（NULL も引くなら `IS NOT DISTINCT FROM` を使うか、`:${paramName} IS NULL OR col = :${paramName}` と書く）"

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

    def isOptional(queryDef: Query, name: String): Bool =
        queryDef#params |> List.exists(param -> param#name == name and param#optional)

}
