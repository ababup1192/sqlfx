///
/// テナントの列（`project_id` など）を持つ表を触る query に、その列の条件があるかの検査。
/// マルチテナントで「条件を書き忘れた query」を生成の時点で止める。RLS はこれの後ろの壁。
///
/// 例外にしたい query は、その直前の行に `// unscoped: 理由` と書く（hash で鍵を引いてから表側でテナントを照合する、など）。
///
/// WhyNot: `列 = :param` の形まで見ないのは、`project_id IN (...)` や JOIN の ON 句など書き方が幅広く、
/// 「列の名前が本文に 1 度も出ない」事だけを見れば書き忘れは捕まえられるため。
///
mod QScope {

    use Schema.Schema
    use QueryDef.Query

    pub enum ScopeError with Eq, Order, ToString {
        /// (クエリ名, テーブル名, 列名) その表を触るのに列の条件が無く、`// unscoped:` の印も無い
        case Unscoped(String, String, String)
    }

    ///
    /// 全 query を検査する。source は `// unscoped:` の印を探すための .q の本文。
    ///
    pub def check(column: String, schema: Schema, source: String, queries: List[Query]): Result[ScopeError, Unit] =
        let exempt = unscopedNames(source);
        queries
            |> List.filter(queryDef -> not List.memberOf(queryDef#name, exempt))
            |> List.findMap(queryDef -> violation(column, schema, queryDef))
            |> Option.toErr(())
            |> Result.map(_ -> ())

    ///
    /// `// unscoped:` の直後の `query 名` を集める。
    ///
    pub def unscopedNames(source: String): List[String] =
        String.lines(source)
            |> List.map(String.trim)
            |> collect(false, Nil)

    def collect(marked: Bool, acc: List[String], lines: List[String]): List[String] = match lines {
        case Nil => List.reverse(acc)
        case line :: rest if String.startsWith(prefix = "// unscoped:", line) => collect(true, acc, rest)
        case line :: rest if marked and String.startsWith(prefix = "query ", line) =>
            let name = String.drop(6, line) |> String.takeWhile(ch -> Char.isLetterOrDigit(ch) or ch == '_');
            collect(false, name :: acc, rest)
        case _ :: rest => collect(false, acc, rest)
    }

    ///
    /// 1 つの query の違反。触る表のうち列を持つ物があり、本文に列の名前が無ければ Some。
    ///
    def violation(column: String, schema: Schema, queryDef: Query): Option[ScopeError] =
        let (sql, _) = QRender.toSql(queryDef);
        let words = SqlTokens.tokenize(sql);
        if (List.exists(word -> String.toLowerCase(word) == column, words)) None
        else
            touchedTables(schema, words)
                |> List.find(table -> Schema.findTable(table, schema) |> Option.exists(found -> Option.nonEmpty(Schema.findColumn(column, found))))
                |> Option.map(table -> ScopeError.Unscoped(queryDef#name, table, column))

    ///
    /// FROM / JOIN / INTO / UPDATE の直後の語のうち、スキーマにある表。
    ///
    def touchedTables(schema: Schema, words: List[String]): List[String] =
        List.zip(words, List.drop(1, words))
            |> List.filterMap(match (keyword, name) ->
                if (List.memberOf(String.toUpperCase(keyword), List#{"FROM", "JOIN", "INTO", "UPDATE"}) and Map.memberOf(name, schema)) Some(name) else None)

}
