///
/// テナントの列（`project_id` など）を持つ表を触る query に、その列の条件があるかの検査。
/// マルチテナントで「条件を書き忘れた query」を生成の時点で止める。RLS はこれの後ろの壁。
///
/// 例外にしたい query は、その前の行に `// unscoped: 理由` と書く（hash で鍵を引いてから表側でテナントを照合する、など）。
/// 印と `query` の間には普通の `//` コメントと空行を挟んでよい。それ以外の行やファイル末尾に当たった印は
/// dangling として生成を止める。
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
        /// (印の行番号。1 始まり) 印の後に `query` が来ないまま、コメントでも空行でもない行かファイル末尾に当たった
        case DanglingMarker(Int32)
        /// (クエリ名) 印が指す名前の query がファイルに無い
        case UnknownMarkedQuery(String)
    }

    ///
    /// エラーを、規則・受け取った値・直し方の 3 つが分かる 1 行にする。
    ///
    pub def describe(error: ScopeError): String = match error {
        case ScopeError.Unscoped(name, table, column) =>
            "query ${name} が ${table} を触るのに ${column} の条件が無い。意図した物なら前の行に `// unscoped: 理由` を書く"
        case ScopeError.DanglingMarker(at) =>
            "${at} 行目の `// unscoped:` の後に query が無い。印は query の前に置き、間に挟んでよいのは `//` コメントと空行だけ"
        case ScopeError.UnknownMarkedQuery(name) =>
            "`// unscoped:` の印が指す query ${name} がこのファイルに無い。名前を query の物と揃える"
    }

    ///
    /// 全 query を検査する。source は `// unscoped:` の印を探すための .q の本文。
    ///
    pub def check(column: String, schema: Schema, source: String, queries: List[Query]): Result[ScopeError, Unit] =
        forM (
            exempt <- markedNames(prefix = "// unscoped:", source);
            _ <- exempt
                |> List.find(name -> not List.exists(queryDef -> queryDef#name == name, queries))
                |> Option.map(ScopeError.UnknownMarkedQuery)
                |> Option.toErr(());
            _ <- queries
                |> List.filter(queryDef -> not List.memberOf(queryDef#name, exempt))
                |> List.findMap(queryDef -> violation(column, schema, queryDef))
                |> Option.toErr(())
        ) yield ()

    ///
    /// `prefix` で始まる印の行が指す `query 名` を、ファイルに出る順に集める。
    /// 印の後は `//` コメントと空行を読み飛ばして `query` を探し、それ以外に当たれば DanglingMarker。
    /// `// scope: explicit` のような別の印も同じ関数で拾う想定（prefix を変えるだけ）。
    ///
    pub def markedNames(prefix: {prefix = String}, source: String): Result[ScopeError, List[String]] =
        String.lines(source)
            |> List.map(String.trim)
            |> List.zipWithIndex
            |> collect(prefix#prefix, None, Nil)

    ///
    /// `marked` は直前に見た印の行番号（1 始まり）。lines は (0 始まりの添字, 行) の列。
    ///
    def collect(prefix: String, marked: Option[Int32], acc: List[String], lines: List[(Int32, String)]): Result[ScopeError, List[String]] = match (marked, lines) {
        case (None, Nil) => Ok(List.reverse(acc))
        case (Some(at), Nil) => Err(ScopeError.DanglingMarker(at))
        case (Some(at), (_, line) :: _) if String.startsWith(prefix = prefix, line) => Err(ScopeError.DanglingMarker(at))
        case (None, (index, line) :: rest) if String.startsWith(prefix = prefix, line) => collect(prefix, Some(index + 1), acc, rest)
        case (Some(_), (_, line) :: rest) if String.startsWith(prefix = "query ", line) => collect(prefix, None, queryName(line) :: acc, rest)
        case (Some(_), (_, line) :: rest) if String.isEmpty(line) or String.startsWith(prefix = "//", line) => collect(prefix, marked, acc, rest)
        case (Some(at), _ :: _) => Err(ScopeError.DanglingMarker(at))
        case (None, _ :: rest) => collect(prefix, None, acc, rest)
    }

    ///
    /// `query 名(...)` の行から名前だけを取る。
    ///
    def queryName(line: String): String =
        String.drop(6, line) |> String.takeWhile(ch -> Char.isLetterOrDigit(ch) or ch == '_')

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
