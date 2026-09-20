///
/// テナントの列（`project_id` など）を持つ表を触る query に、その列の条件があるかの検査と、
/// その列の値を生成関数の引数から外して effect から取る「注入」の判定。
/// マルチテナントで「条件を書き忘れた query」と「別のテナントの id を渡してしまう呼び出し」を生成の時点で止める。RLS はこれの後ろの壁。
///
/// 例外にしたい query は、その前の行に `// unscoped: [列] 理由` と書く（hash で鍵を引いてから表側でテナントを照合する、など）。
/// 検査は受けるが id を手で渡したい query は `// scope: explicit [列] 理由`（Tenant を持たない文脈から呼ぶ物）。
/// 列を書けばその列だけ、省けば `--scope` の全部の列に効く。印と `query` の間には普通の `//` コメントと空行を挟んでよい。
/// それ以外の行やファイル末尾に当たった印は dangling として生成を止める。
///
/// WhyNot: `列 = :param` の形まで見ないのは、`project_id IN (...)` や JOIN の ON 句など書き方が幅広く、
/// 「列の名前が本文に 1 度も出ない」事だけを見れば書き忘れは捕まえられるため。
/// WhyNot: 注入する引数を「列の camelCase で必須の Int64」に限るのは、値の式が `<effect>.currentId()` に固定で、
/// 別名の引数まで拾うと `IN (...)` の配列や JOIN の相手の id を取り違えるため。名前だけ合って型が違う物はエラーにして気づかせる。
///
mod QScope {

    use Schema.Schema
    use QueryDef.Query
    use SqlType.SqlType

    ///
    /// `--scope <列>[:<effect>]` の 1 つ分。
    ///
    /// - `column`: テナントの列名
    /// - `effect`: あれば、その列の camelCase の引数を生成関数から外し `<effect>.currentId()` で埋める。無ければ検査だけ
    ///
    pub type alias Scope = { column = String, effect = Option[String] }

    ///
    /// 生成関数の引数から外して effect から取る引数 1 つ。
    ///
    /// - `param`: 引数名（列の camelCase）
    /// - `effect`: 値を取る effect の名前。生成物は `<effect>.currentId()` を呼ぶ
    ///
    pub type alias Injection = { param = String, effect = String }

    pub enum ScopeError with Eq, Order, ToString {
        /// (クエリ名, テーブル名, 列名) その表を触るのに列の条件が無く、`// unscoped:` の印も無い
        case Unscoped(String, String, String)
        /// (印の行番号。1 始まり) 印の後に `query` が来ないまま、コメントでも空行でもない行かファイル末尾に当たった
        case DanglingMarker(Int32)
        /// (クエリ名) 印が指す名前の query がファイルに無い
        case UnknownMarkedQuery(String)
        /// (クエリ名, 列名) 印に書いた列がスキーマの列だが `--scope` に無い
        case MarkerColumnNotScoped(String, String)
        /// (クエリ名, 引数名, 列名, 受け取った型) 列の camelCase の引数があるが、必須の Int64 でないので注入できない
        case UninjectableParam(String, String, String, String)
    }

    ///
    /// エラーを、規則・受け取った値・直し方の 3 つが分かる 1 行にする。
    ///
    pub def describe(error: ScopeError): String = match error {
        case ScopeError.Unscoped(name, table, column) =>
            "query ${name} touches ${table} with no condition on ${column}. If that is intended, write `// unscoped: <reason>` on the line before the query"
        case ScopeError.DanglingMarker(at) =>
            "the marker on line ${at} (`// unscoped:` / `// scope: explicit`) is not followed by a query. Put the marker before the query; only `//` comments and blank lines may come between"
        case ScopeError.UnknownMarkedQuery(name) =>
            "the marker points at query ${name}, which is not in this file. Match the name to the query's"
        case ScopeError.MarkerColumnNotScoped(name, column) =>
            "column ${column} in the marker of query ${name} is not in `--scope`. If you name a column, it must be one of `--scope`; if the reason itself starts with a column name, put the column first"
        case ScopeError.UninjectableParam(name, param, column, received) =>
            "parameter ${param} of query ${name} has the name that is filled from the effect as the value of ${column}, but its type is ${received}. Make it a required Int64, rename it, or, to pass it by hand, write `// scope: explicit ${column} <reason>` on the line before the query"
    }

    ///
    /// 列 1 つの検査だけ。source は印を探すための .q の本文。
    ///
    pub def check(column: String, schema: Schema, source: String, queries: List[Query]): Result[ScopeError, Unit] =
        plan(List#{{ column = column, effect = None }}, schema, source, queries) |> Result.map(_ -> ())

    ///
    /// 全 scope の検査を通し、query 名 → 注入する引数（scope の順）を返す。scope が無ければ印も読まない。
    ///
    pub def plan(scopes: List[Scope], schema: Schema, source: String, queries: List[Query]): Result[ScopeError, Map[String, List[Injection]]] =
        if (List.isEmpty(scopes)) Ok(Map.empty())
        else
            forM (
                unscoped <- markedColumns(prefix = "// unscoped:", scopes, schema, source, queries);
                explicit <- markedColumns(prefix = "// scope: explicit", scopes, schema, source, queries);
                plans <- List.traverse(scope -> planScope(scope, schema, unscoped, explicit, queries), scopes)
            ) yield
                List.flatten(plans)
                    |> List.foldLeft((acc, entry) -> {
                        let (name, injection) = entry;
                        Map.insert(name, List.append(Map.getWithDefault(name, Nil, acc), List#{injection}), acc)
                    }, Map.empty())

    ///
    /// 1 つの scope について、免除されていない query の違反を探し、通った物の注入を決める。
    ///
    def planScope(scope: Scope, schema: Schema, unscoped: List[(String, Option[String])], explicit: List[(String, Option[String])], queries: List[Query]): Result[ScopeError, List[(String, Injection)]] =
        queries
            |> List.filter(queryDef -> not marked(unscoped, scope#column, queryDef#name))
            |> List.traverse(queryDef -> match violation(scope#column, schema, queryDef) {
                case Some(error) => Err(error)
                case None => injection(scope, schema, explicit, queryDef) |> Result.map(Option.map(found -> (queryDef#name, found)))
            })
            |> Result.map(List.filterMap(identity))

    ///
    /// (query 名, 列) の印がその query のその列に効くか。列が None の印は全部の列に効く。
    ///
    def marked(marks: List[(String, Option[String])], column: String, name: String): Bool =
        List.exists(match (markedName, markedColumn) -> markedName == name and (markedColumn == None or markedColumn == Some(column)), marks)

    ///
    /// 注入する引数。effect の無い scope、explicit の query、列を持つ表を触らない query、列の camelCase の引数が無い query は None。
    ///
    def injection(scope: Scope, schema: Schema, explicit: List[(String, Option[String])], queryDef: Query): Result[ScopeError, Option[Injection]] =
        match scope#effect {
            case None => Ok(None)
            case Some(effect) =>
                if (marked(explicit, scope#column, queryDef#name) or List.isEmpty(scopedTables(scope#column, schema, queryDef))) Ok(None)
                else match List.find(param -> param#name == Codegen.fieldName(scope#column), queryDef#params) {
                    case None => Ok(None)
                    case Some(param) if param#paramType == SqlType.Int64 and not param#optional => Ok(Some({ param = param#name, effect = effect }))
                    case Some(param) => Err(ScopeError.UninjectableParam(queryDef#name, param#name, scope#column, paramSpelling(param)))
                }
        }

    ///
    /// `.q` に書く綴りで引数の型を返す（エラーの文言用）。
    ///
    def paramSpelling(param: QueryDef.Param): String =
        let flixName = SqlType.spec(param#paramType)#flixName;
        if (param#optional) "Option[${flixName}]" else flixName

    ///
    /// `prefix` で始まる印の行が指す `query 名` を、ファイルに出る順に集める。
    /// 印の後は `//` コメントと空行を読み飛ばして `query` を探し、それ以外に当たれば DanglingMarker。
    ///
    pub def markedNames(prefix: {prefix = String}, source: String): Result[ScopeError, List[String]] =
        markedEntries(prefix, source) |> Result.map(List.map(fst))

    ///
    /// `markedNames` に、印の行の prefix より後ろ（列名と理由。前後の空白は落とす）を添えた物。
    ///
    pub def markedEntries(prefix: {prefix = String}, source: String): Result[ScopeError, List[(String, String)]] =
        String.lines(source)
            |> List.map(String.trim)
            |> List.zipWithIndex
            |> collect(prefix#prefix, None, Nil)

    ///
    /// `marked` は直前に見た印の (行番号（1 始まり）, prefix より後ろ)。lines は (0 始まりの添字, 行) の列。
    ///
    def collect(prefix: String, marked: Option[(Int32, String)], acc: List[(String, String)], lines: List[(Int32, String)]): Result[ScopeError, List[(String, String)]] = match (marked, lines) {
        case (None, Nil) => Ok(List.reverse(acc))
        case (Some((at, _)), Nil) => Err(ScopeError.DanglingMarker(at))
        case (Some((at, _)), (_, line) :: _) if String.startsWith(prefix = prefix, line) => Err(ScopeError.DanglingMarker(at))
        case (None, (index, line) :: rest) if String.startsWith(prefix = prefix, line) => collect(prefix, Some((index + 1, String.trim(String.drop(String.length(prefix), line)))), acc, rest)
        case (Some((_, tail)), (_, line) :: rest) if String.startsWith(prefix = "query ", line) => collect(prefix, None, (queryName(line), tail) :: acc, rest)
        case (Some(_), (_, line) :: rest) if String.isEmpty(line) or String.startsWith(prefix = "//", line) => collect(prefix, marked, acc, rest)
        case (Some((at, _)), _ :: _) => Err(ScopeError.DanglingMarker(at))
        case (None, _ :: rest) => collect(prefix, None, acc, rest)
    }

    ///
    /// `query 名(...)` の行から名前だけを取る。
    ///
    def queryName(line: String): String =
        String.drop(6, line) |> String.takeWhile(ch -> Char.isLetterOrDigit(ch) or ch == '_')

    ///
    /// 印を (query 名, 効く列) にする。印の最初の語が `--scope` の列ならその列、スキーマにある別の列ならエラー、それ以外は理由の書き出しで全部の列。
    ///
    def markedColumns(prefix: {prefix = String}, scopes: List[Scope], schema: Schema, source: String, queries: List[Query]): Result[ScopeError, List[(String, Option[String])]] =
        markedEntries(prefix, source)
            |> Result.flatMap(List.traverse(match (name, tail) ->
                if (not List.exists(queryDef -> queryDef#name == name, queries)) Err(ScopeError.UnknownMarkedQuery(name))
                else {
                    let word = String.takeWhile(ch -> not Char.isWhitespace(ch), tail);
                    if (List.exists(scope -> scope#column == word, scopes)) Ok((name, Some(word)))
                    else if (isColumnAnywhere(word, schema)) Err(ScopeError.MarkerColumnNotScoped(name, word))
                    else Ok((name, None))
                }))

    def isColumnAnywhere(column: String, schema: Schema): Bool =
        Map.valuesOf(schema) |> List.exists(table -> Option.nonEmpty(Schema.findColumn(column, table)))

    ///
    /// 1 つの query の違反。触る表のうち列を持つ物があり、本文に列の名前が無ければ Some。
    ///
    def violation(column: String, schema: Schema, queryDef: Query): Option[ScopeError] =
        let (sql, _) = QRender.toSql(queryDef);
        let words = SqlTokens.tokenize(sql);
        if (List.exists(word -> String.toLowerCase(word) == column, words)) None
        else
            scopedTables(column, schema, queryDef)
                |> List.head
                |> Option.map(table -> ScopeError.Unscoped(queryDef#name, table, column))

    ///
    /// query が触る表のうち、列を持つ物。
    ///
    def scopedTables(column: String, schema: Schema, queryDef: Query): List[String] =
        let (sql, _) = QRender.toSql(queryDef);
        touchedTables(schema, SqlTokens.tokenize(sql))
            |> List.filter(table -> Schema.findTable(table, schema) |> Option.exists(found -> Option.nonEmpty(Schema.findColumn(column, found))))

    ///
    /// FROM / JOIN / INTO / UPDATE の直後の語のうち、スキーマにある表。
    ///
    def touchedTables(schema: Schema, words: List[String]): List[String] =
        List.zip(words, List.drop(1, words))
            |> List.filterMap(match (keyword, name) ->
                if (List.memberOf(String.toUpperCase(keyword), List#{"FROM", "JOIN", "INTO", "UPDATE"}) and Map.memberOf(name, schema)) Some(name) else None)

}
