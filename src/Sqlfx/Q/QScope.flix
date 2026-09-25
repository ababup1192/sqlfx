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
/// 表ごとに列が引数（か、引数に縛られた表の列）と比べられているかを見る（R1〜R4。設計 docs/design/cte-and-fatal.md の 1.8）。
/// WITH を含む query は CTE の本文 1 つずつと本文を単位に、WITH の無い query は文全体を 1 つの単位に見る。
/// WITH を含む query の `// unscoped:` は、免除する文を `// unscoped: [列] in <CTE の名前 | main>[, ...] 理由` で名指しする。
/// WhyNot: 注入する引数を「列の camelCase で必須の Int64」に限るのは、値の式が `<effect>.currentId()` に固定で、
/// 別名の引数まで拾うと `IN (...)` の配列や JOIN の相手の id を取り違えるため。名前だけ合って型が違う物はエラーにして気づかせる。
///
pub mod Sqlfx.Q.QScope {

    use Sqlfx.Q.Codegen
    use Sqlfx.Q.QCte
    use Sqlfx.Q.QRender
    use Sqlfx.Q.QueryDef
    use Sqlfx.Q.Schema
    use Sqlfx.Q.SqlTokens
    use Sqlfx.Q.SqlType

    use Sqlfx.Q.Schema.Schema
    use Sqlfx.Q.QueryDef.Query
    use Sqlfx.Q.SqlType.SqlType

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
        /// (クエリ名, テーブル名, 列名) その表の列が引数（か、縛られた表の列）と比べられておらず、`// unscoped:` の marker も無い
        case Unscoped(String, String, String)
        /// (印の行番号。1 始まり) 印の後に `query` が来ないまま、コメントでも空行でもない行かファイル末尾に当たった
        case DanglingMarker(Int32)
        /// (クエリ名) 印が指す名前の query がファイルに無い
        case UnknownMarkedQuery(String)
        /// (クエリ名, 列名) 印に書いた列がスキーマの列だが `--scope` に無い
        case MarkerColumnNotScoped(String, String)
        /// (クエリ名, 引数名, 列名, 受け取った型) 列の camelCase の引数があるが、必須の Int64 でないので注入できない
        case UninjectableParam(String, String, String, String)
        /// (クエリ名, テーブル名, 列名, 文の名前) WITH を含む query のその文（CTE の名前か main）で、表の列が引数に縛られていない
        case UnscopedInStatement(String, String, String, String)
        /// (クエリ名) WITH を含む query の `// unscoped:` に、免除する文の名前（`in <名前>`）が無い
        case UnscopedMarkerNeedsStatement(String)
        /// (クエリ名, 名前) `// unscoped: in` の名前が、その query の CTE でも main でもない
        case UnknownMarkedStatement(String, String)
    }

    ///
    /// エラーを、規則・受け取った値・直し方の 3 つが分かる 1 行にする。
    ///
    pub def describe(error: ScopeError): String = match error {
        case ScopeError.Unscoped(name, table, column) =>
            "query ${name} touches ${table} with no condition that ties ${table}.${column} to a parameter. Compare it with a parameter, join it to a table that is, or, if that is intended, write `// unscoped: <reason>` on the line before the query"
        case ScopeError.DanglingMarker(at) =>
            "the marker on line ${at} (`// unscoped:` / `// scope: explicit`) is not followed by a query. Put the marker before the query; only `//` comments and blank lines may come between"
        case ScopeError.UnknownMarkedQuery(name) =>
            "the marker points at query ${name}, which is not in this file. Match the name to the query's"
        case ScopeError.MarkerColumnNotScoped(name, column) =>
            "column ${column} in the marker of query ${name} is not in `--scope`. If you name a column, it must be one of `--scope`; if the reason itself starts with a column name, put the column first"
        case ScopeError.UnscopedInStatement(name, table, column, statement) => {
            let place = if (statement == "main") "in the main statement" else "in CTE ${statement}";
            "query ${name} touches ${table} ${place} with no condition that ties ${table}.${column} to a parameter. Compare it with a parameter, join it to a table that is, or write // unscoped: in ${statement} <reason>"
        }
        case ScopeError.UnscopedMarkerNeedsStatement(name) =>
            "query ${name} has WITH, so // unscoped: must name the statements it exempts: // unscoped: in <CTE name or main> <reason>"
        case ScopeError.UnknownMarkedStatement(name, statement) =>
            "// unscoped: of query ${name} names ${statement}, which is neither a CTE of the query nor main"
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
    def planScope(scope: Scope, schema: Schema, unscoped: List[Mark], explicit: List[Mark], queries: List[Query]): Result[ScopeError, List[(String, Injection)]] =
        queries
            |> List.traverse(queryDef -> {
                let marks = marksOf(unscoped, scope#column, queryDef#name);
                match statementsOf(queryDef) {
                    case Some(units) =>
                        forM (
                            exempt <- exemptStatements(queryDef#name, units, marks);
                            _ <- units |> List.filter(match (label, _) -> not List.memberOf(label, exempt)) |> List.findMap(match (label, words) ->
                                    strictViolations(scope#column, schema, words) |> List.head |> Option.map(table -> ScopeError.UnscopedInStatement(queryDef#name, table, scope#column, label))) |> toErr;
                            found <- injection(scope, schema, explicit, queryDef)
                        ) yield found |> Option.map(injected -> (queryDef#name, injected))
                    case None if not List.isEmpty(marks) => Ok(None)
                    case None => match violation(scope#column, schema, queryDef) {
                        case Some(error) => Err(error)
                        case None => injection(scope, schema, explicit, queryDef) |> Result.map(Option.map(found -> (queryDef#name, found)))
                    }
                }
            })
            |> Result.map(List.filterMap(identity))

    ///
    /// `// unscoped:` / `// scope: explicit` の印 1 つ: (query 名, 効く列, `in` で名指しした文)。
    ///
    type alias Mark = (String, Option[String], Option[List[String]])

    ///
    /// その query のその列に効く印の、名指しした文の並び（`in` が無ければ None）。
    ///
    def marksOf(marks: List[Mark], column: String, name: String): List[Option[List[String]]] =
        marks |> List.filterMap(match (markedName, markedColumn, statements) ->
            if (markedName == name and (markedColumn == None or markedColumn == Some(column))) Some(statements) else None)

    ///
    /// WITH を含む query の免除する文。`in` の無い印は UnscopedMarkerNeedsStatement、無い名前は UnknownMarkedStatement。
    ///
    def exemptStatements(name: String, units: List[(String, List[String])], marks: List[Option[List[String]]]): Result[ScopeError, List[String]] =
        let labels = List.map(fst, units);
        marks |> List.traverse(statements -> match statements {
            case None => Err(ScopeError.UnscopedMarkerNeedsStatement(name))
            case Some(named) => match List.find(one -> not List.memberOf(one, labels), named) {
                case Some(unknown) => Err(ScopeError.UnknownMarkedStatement(name, unknown))
                case None => Ok(named)
            }
        }) |> Result.map(List.flatten)

    ///
    /// WITH を含む query なら、検査の単位（CTE の名前と本文の語、最後に ("main", 本文の語)）。WITH が無いか切れなければ None。
    ///
    /// WhyNot: 切れない WITH（RECURSIVE・入れ子）を粗い検査に倒すのは、それを断るのは QResolve で、ここで別のエラーにすると
    /// 同じ query に 2 通りのメッセージが出るため。
    ///
    def statementsOf(queryDef: Query): Option[List[(String, List[String])]] =
        let (sql, _) = QRender.toSql(queryDef);
        match QCte.split(SqlTokens.tokenize(sql)) {
            case Ok(statement) if not List.isEmpty(statement#ctes) =>
                Some(List.map(cte -> (cte#name, cte#body#words), statement#ctes) ::: ("main", statement#main#words) :: Nil)
            case _ => None
        }

    def toErr(error: Option[ScopeError]): Result[ScopeError, Unit] = match error {
        case Some(e) => Err(e)
        case None => Ok(())
    }

    ///
    /// (query 名, 列) の印がその query のその列に効くか。列が None の印は全部の列に効く。
    ///
    def marked(marks: List[Mark], column: String, name: String): Bool =
        not List.isEmpty(marksOf(marks, column, name))

    ///
    /// 注入する引数。effect の無い scope、explicit の query、列を持つ表を触らない query、列の camelCase の引数が無い query は None。
    ///
    def injection(scope: Scope, schema: Schema, explicit: List[Mark], queryDef: Query): Result[ScopeError, Option[Injection]] =
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
    def markedColumns(prefix: {prefix = String}, scopes: List[Scope], schema: Schema, source: String, queries: List[Query]): Result[ScopeError, List[Mark]] =
        markedEntries(prefix, source)
            |> Result.flatMap(List.traverse(match (name, tail) ->
                if (not List.exists(queryDef -> queryDef#name == name, queries)) Err(ScopeError.UnknownMarkedQuery(name))
                else {
                    let words = String.words(tail);
                    let word = List.head(words) |> Option.getWithDefault("");
                    if (List.exists(scope -> scope#column == word, scopes)) Ok((name, Some(word), namedStatements(List.drop(1, words))))
                    else if (isColumnAnywhere(word, schema)) Err(ScopeError.MarkerColumnNotScoped(name, word))
                    else Ok((name, None, namedStatements(words)))
                }))

    ///
    /// `in a, b 理由` の文の名前。`in` で始まらなければ None。名前はカンマで続け、カンマの付かない名前で終わる。
    ///
    def namedStatements(words: List[String]): Option[List[String]] =
        match words {
            case "in" :: rest =>
                let continued = List.takeWhile(String.endsWith(suffix = ","), rest);
                let last = List.drop(List.length(continued), rest) |> List.head |> Option.toList;
                Some(List.map(String.dropRight(1), continued) ::: last |> List.map(String.toLowerCase))
            case _ => None
        }

    def isColumnAnywhere(column: String, schema: Schema): Bool =
        Map.valuesOf(schema) |> List.exists(table -> Option.nonEmpty(Schema.findColumn(column, table)))

    ///
    /// 1 つの query の違反。触る表のうち列を持つ物があり、本文に列の名前が無ければ Some。
    ///
    def violation(column: String, schema: Schema, queryDef: Query): Option[ScopeError] =
        let (sql, _) = QRender.toSql(queryDef);
        strictViolations(column, schema, SqlTokens.tokenize(sql))
            |> List.head
            |> Option.map(table -> ScopeError.Unscoped(queryDef#name, table, column))

    ///
    /// query が触る表のうち、列を持つ物。
    ///
    def scopedTables(column: String, schema: Schema, queryDef: Query): List[String] =
        let (sql, _) = QRender.toSql(queryDef);
        touchedTables(schema, SqlTokens.tokenize(sql))
            |> List.filter(hasColumn(column, schema))
            |> List.distinct

    def hasColumn(column: String, schema: Schema, table: String): Bool =
        Schema.findTable(table, schema) |> Option.exists(found -> Option.nonEmpty(Schema.findColumn(column, found)))

    // ---- 触る表（R1）----

    ///
    /// 触る表の名前（R1）。FROM / JOIN / INTO / UPDATE / USING の後ろと、FROM / USING のカンマの続き。深さを問わない。
    /// 表の綴りは `ONLY t`、`public.t`、`"t"` を `t` に揃える。スキーマに無い名前（CTE、関数）は数えない。
    ///
    def touchedTables(schema: Schema, words: List[String]): List[String] =
        touches(schema, List.toVector(words)) |> List.map(touch -> touch#table)

    ///
    /// 触る表 1 つ。
    ///
    /// - `table`: 表の名前
    /// - `label`: 文の中の名前（alias が無ければ表の名前）
    /// - `insertTarget`: INSERT の書き込み先か。書き込み先は R3 で見て、修飾の無いカラムの解き先にしない
    /// - `scope`: 表を置いた副問い合わせ（囲む `(` の位置。一番外は -1）
    ///
    type alias Touch = { table = String, label = String, insertTarget = Bool, scope = Int32 }

    def touches(schema: Schema, words: Vector[String]): List[Touch] =
        List.range(0, Vector.length(words)) |> List.flatMap(i -> {
            let keyword = upperAt(i, words);
            if (List.memberOf(keyword, List#{"FROM", "JOIN", "INTO", "UPDATE", "USING"})) {
                let (next, first) = readTableRef(i + 1, words, schema, keyword == "INTO");
                let rest = if (keyword == "FROM" or keyword == "USING") commaChain(next, words, schema) else Nil;
                Option.toList(first) ::: rest
            } else Nil
        })

    ///
    /// i から表を 1 つ読む。戻りは (続きの位置, 表)。スキーマに無ければ表は None。
    ///
    def readTableRef(i: Int32, words: Vector[String], schema: Schema, insertTarget: Bool): (Int32, Option[Touch]) =
        let scope = innermostParen(i, words);
        let start = if (upperAt(i, words) == "ONLY") i + 1 else i;
        let (name, afterName) = if (wordAt(start + 1, words) == ".") (wordAt(start + 2, words), start + 3) else (wordAt(start, words), start + 1);
        if (not Map.memberOf(name, schema)) (afterName, None)
        else {
            let next = wordAt(afterName, words);
            let touch = label -> Some({ table = name, label = label, insertTarget = insertTarget, scope = scope });
            if (String.toUpperCase(next) == "AS") (afterName + 2, touch(wordAt(afterName + 1, words)))
            else if (isAlias(next)) (afterName + 1, touch(next))
            else (afterName, touch(name))
        }

    def commaChain(i: Int32, words: Vector[String], schema: Schema): List[Touch] =
        if (wordAt(i, words) != ",") Nil
        else {
            let (next, found) = readTableRef(i + 1, words, schema, false);
            match found {
                case None => Nil
                case Some(touch) => touch :: commaChain(next, words, schema)
            }
        }

    def isAlias(word: String): Bool =
        not String.isEmpty(word) and Char.isLetter(String.charAt(0, word)) and not List.memberOf(String.toUpperCase(word), aliasStoppers())

    def aliasStoppers(): List[String] =
        List#{"WHERE", "JOIN", "ON", "SET", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "USING", "RETURNING", "GROUP", "ORDER", "LIMIT",
              "OFFSET", "HAVING", "VALUES", "SELECT", "UNION", "EXCEPT", "INTERSECT", "FOR", "WINDOW", "NATURAL", "LATERAL", "DEFAULT", "DO",
              "AND", "OR", "NOT", "WITH", "AS", "FROM", "INTO", "UPDATE", "DELETE", "INSERT", "TABLESAMPLE"}

    ///
    /// i を囲む `(` の位置（内側から）。
    ///
    def enclosing(i: Int32, words: Vector[String]): List[Int32] =
        List.range(0, i) |> List.foldLeft((stack, j) ->
            if (wordAt(j, words) == "(") j :: stack else if (wordAt(j, words) == ")") List.drop(1, stack) else stack, Nil)

    def innermostParen(i: Int32, words: Vector[String]): Int32 =
        enclosing(i, words) |> List.head |> Option.getWithDefault(-1)

    // ---- 縛られているか（R2〜R4）----

    ///
    /// 1 つの単位の中で、scope の列が縛られていない表（書き込み先以外を先に、出た順）。
    ///
    /// - R2: 表（か label）の列が引数（`= $n`、`= ANY($n)`、`IN ($n)`）と比べられているか、縛られた別の表の列と `=` で比べられている
    /// - R3: INSERT の書き込み先は、列の並びのその位置の値が引数か、縛られた読み元の列
    /// - R4: SELECT リスト・文字列・コメントは「縛る」に数えない（比べる式だけを見るので、どれも数えない）
    ///
    /// WhyNot: 修飾の無い列を、囲む副問い合わせの内側から外へ解く（PG と同じ）。全部の表から探すと、
    /// `DELETE FROM entries WHERE id = ANY(ARRAY(SELECT id FROM entries WHERE project_id = $1)) AND project_id = $1` を曖昧として止める。
    ///
    def strictViolations(column: String, schema: Schema, wordList: List[String]): List[String] =
        let words = List.toVector(wordList);
        let all = touches(schema, words);
        let bound = boundLabels(column, schema, all, words);
        let unbound = all
            |> List.filter(touch -> hasColumn(column, schema, touch#table))
            |> List.filter(touch -> if (touch#insertTarget) not insertBound(column, schema, all, bound, words, touch) else not Set.memberOf(keyOf(touch), bound));
        let (targets, sources) = List.partition(touch -> touch#insertTarget, unbound);
        (sources ::: targets) |> List.map(touch -> touch#table) |> List.distinct

    ///
    /// 比べる式の片側。
    ///
    enum Side {
        /// `$n`（`$n::type`、`ANY($n)` も）
        case Param
        /// 列の参照（label, 列, 語の位置）
        case Ref(Option[String], String, Int32)
        /// それ以外の式
        case Other
    }

    ///
    /// `a = b` と `a IN ($n)` の組。UPDATE の SET 句（`ON CONFLICT DO UPDATE SET` も）の中は代入なので除く。
    ///
    def comparisons(words: Vector[String]): List[(Side, Side)] =
        let excluded = setClauses(words);
        List.range(0, Vector.length(words)) |> List.filterMap(i ->
            if (List.exists(match (start, end) -> i > start and i < end, excluded)) None
            else if (wordAt(i, words) == "=") Some((leftSide(i, words), rightSide(i + 1, words)))
            else if (upperAt(i, words) == "IN" and wordAt(i + 1, words) == "(" and isParam(wordAt(i + 2, words))) Some((leftSide(i, words), Side.Param))
            else None)

    ///
    /// 演算子の位置 i の左の片側。`$n`・`$n::type`・`label.col`・`col`。
    ///
    def leftSide(i: Int32, words: Vector[String]): Side =
        if (isParam(wordAt(i - 1, words))) Side.Param
        else if (wordAt(i - 2, words) == "::" and isParam(wordAt(i - 3, words))) Side.Param
        else if (wordAt(i - 2, words) == ".") Side.Ref(Some(wordAt(i - 3, words)), wordAt(i - 1, words), i)
        else if (isName(wordAt(i - 1, words))) Side.Ref(None, wordAt(i - 1, words), i)
        else Side.Other

    ///
    /// 位置 i から始まる右の片側。`$n`・`ANY($n)`・`label.col`・`col`。
    ///
    def rightSide(i: Int32, words: Vector[String]): Side =
        let word = wordAt(i, words);
        if (isParam(word)) Side.Param
        else if (String.toUpperCase(word) == "ANY" and wordAt(i + 1, words) == "(" and isParam(wordAt(i + 2, words))) Side.Param
        else if (isName(word) and wordAt(i + 1, words) == ".") Side.Ref(Some(word), wordAt(i + 2, words), i)
        else if (isName(word)) Side.Ref(None, word, i)
        else Side.Other

    ///
    /// SET 句の範囲（SET の位置, 句の終わり）。終わりは同じ文の WHERE / FROM / RETURNING。
    ///
    def setClauses(words: Vector[String]): List[(Int32, Int32)] =
        let total = Vector.length(words);
        List.range(0, total) |> List.filterMap(i ->
            if (upperAt(i, words) != "SET") None
            else Some((i, List.range(i + 1, total) |> List.find(j -> List.memberOf(upperAt(j, words), List#{"WHERE", "FROM", "RETURNING"})) |> Option.getWithDefault(total))))

    ///
    /// 縛られた label（R2）。引数と比べた物から始め、縛られた表と列で結んだ表を足していく。
    ///
    def boundLabels(column: String, schema: Schema, all: List[Touch], words: Vector[String]): Set[String] =
        let pairs = comparisons(words);
        let direct = pairs |> List.filterMap(pair -> match pair {
            case (Side.Ref(label, col, at), Side.Param) if col == column => resolveRef(schema, all, words, at, label, col)
            case (Side.Param, Side.Ref(label, col, at)) if col == column => resolveRef(schema, all, words, at, label, col)
            case _ => None
        }) |> List.toSet;
        let joins = pairs |> List.filterMap(pair -> match pair {
            case (Side.Ref(leftLabel, leftCol, leftAt), Side.Ref(rightLabel, rightCol, rightAt)) if leftCol == column and rightCol == column =>
                forM (
                    left <- resolveRef(schema, all, words, leftAt, leftLabel, leftCol);
                    right <- resolveRef(schema, all, words, rightAt, rightLabel, rightCol)
                ) yield (left, right)
            case _ => None
        });
        spread(direct, joins)

    def spread(bound: Set[String], joins: List[(String, String)]): Set[String] =
        let next = joins |> List.foldLeft((acc, pair) -> {
            let (left, right) = pair;
            if (Set.memberOf(left, acc)) Set.insert(right, acc) else if (Set.memberOf(right, acc)) Set.insert(left, acc) else acc
        }, bound);
        if (next == bound) bound else spread(next, joins)

    ///
    /// 表 1 つを見分ける名前（label と、置いた副問い合わせ）。
    ///
    /// WhyNot: label だけで見分けない。外側と副問い合わせに同じ表を alias 無しで置くと label が同じになり、
    /// 外側を縛っただけで副問い合わせの表まで縛った事になる。
    ///
    def keyOf(touch: Touch): String = "${touch#label}@${touch#scope}"

    ///
    /// 列の参照を表（`keyOf`）に解く。修飾があればその label を、無ければその列を持つ表を、囲む副問い合わせの内側から外へ探す。
    /// 同じ深さに列を持つ表が 2 つ以上あれば曖昧で None（PG も断る）。INSERT の書き込み先は解き先にしない。
    ///
    def resolveRef(schema: Schema, all: List[Touch], words: Vector[String], position: Int32, label: Option[String], col: String): Option[String] =
        let scopes = enclosing(position, words) ::: -1 :: Nil;
        match label {
            case Some(found) =>
                scopes |> List.findMap(scope -> all |> List.find(touch -> touch#scope == scope and touch#label == found)) |> Option.map(keyOf)
            case None =>
                scopes |> List.findMap(scope -> {
                    let owners = all
                        |> List.filter(touch -> not touch#insertTarget and touch#scope == scope and hasColumn(col, schema, touch#table))
                        |> List.map(keyOf)
                        |> List.distinct;
                    match owners {
                        case Nil         => None
                        case one :: Nil  => Some(Some(one))
                        case _           => Some(None)
                    }
                }) |> Option.flatten
        }

    ///
    /// R3: INSERT の書き込み先の scope の列の値が、引数（VALUES）か、引数か縛られた読み元の列（INSERT … SELECT のリストの同じ位置）か。
    ///
    def insertBound(column: String, schema: Schema, all: List[Touch], bound: Set[String], words: Vector[String], target: Touch): Bool =
        let total = Vector.length(words);
        match List.range(0, total) |> List.find(i -> upperAt(i, words) == "INTO" and wordAt(i + 1, words) == target#table and wordAt(i + 2, words) == "(") {
            case None => false
            case Some(intoAt) =>
                let columnsEnd = List.range(intoAt + 3, total) |> List.find(j -> wordAt(j, words) == ")") |> Option.getWithDefault(total);
                let columns = List.range(intoAt + 3, columnsEnd) |> List.map(j -> wordAt(j, words)) |> List.filter(word -> word != ",");
                match List.indexOf(column, columns) {
                    case None => false
                    case Some(index) =>
                        let following = upperAt(columnsEnd + 1, words);
                        if (following == "VALUES")
                            itemsAt(columnsEnd + 3, words) |> List.nth(index) |> Option.exists(item -> List.exists(match (word, _) -> isParam(word), item))
                        else if (following == "SELECT")
                            itemsAt(columnsEnd + 2, words) |> List.nth(index) |> Option.exists(item ->
                                List.exists(match (word, _) -> isParam(word), item) or boundColumnItem(column, schema, all, bound, words, item))
                        else false
                }
        }

    ///
    /// SELECT リストの 1 項目が、縛られた表の scope の列そのもの（`e.project_id` / `project_id`。cast は付いてよい）か。
    ///
    def boundColumnItem(column: String, schema: Schema, all: List[Touch], bound: Set[String], words: Vector[String], item: List[(String, Int32)]): Bool =
        let found = match item {
            case (label, at) :: (".", _) :: (col, _) :: _ => resolveRef(schema, all, words, at, Some(label), col) |> Option.map(resolved -> (resolved, col))
            case (col, at) :: _ => resolveRef(schema, all, words, at, None, col) |> Option.map(resolved -> (resolved, col))
            case Nil => None
        };
        found |> Option.exists(match (resolved, col) -> col == column and Set.memberOf(resolved, bound))

    ///
    /// 位置 i から、深さ 0 のカンマで切った項目（語と位置）。深さ 0 の `)` か FROM で終わる。
    ///
    def itemsAt(i: Int32, words: Vector[String]): List[List[(String, Int32)]] =
        let total = Vector.length(words);
        def go(j: Int32, depth: Int32, current: List[(String, Int32)], acc: List[List[(String, Int32)]]): List[List[(String, Int32)]] =
            if (j >= total) List.reverse(List.reverse(current) :: acc)
            else {
                let word = wordAt(j, words);
                if (depth == 0 and (word == ")" or String.toUpperCase(word) == "FROM")) List.reverse(List.reverse(current) :: acc)
                else if (depth == 0 and word == ",") go(j + 1, depth, Nil, List.reverse(current) :: acc)
                else if (word == "(") go(j + 1, depth + 1, (word, j) :: current, acc)
                else if (word == ")") go(j + 1, depth - 1, (word, j) :: current, acc)
                else go(j + 1, depth, (word, j) :: current, acc)
            };
        go(i, 0, Nil, Nil)

    def isParam(word: String): Bool = String.startsWith(prefix = "$", word) and String.length(word) > 1

    def isName(word: String): Bool = not String.isEmpty(word) and (Char.isLetter(String.charAt(0, word)) or String.charAt(0, word) == '_')

    def wordAt(i: Int32, words: Vector[String]): String = Vector.nth(i, words) |> Option.getWithDefault("")

    def upperAt(i: Int32, words: Vector[String]): String = String.toUpperCase(wordAt(i, words))

}
