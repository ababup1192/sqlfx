///
/// `.q` の SQL を机上のスキーマに当てて、結果の列（名前・型・NULL 可否）を決める。生成器はこの結果から型とデコーダを吐く。
/// 読むのは SELECT の FROM / JOIN とリストだけ。式の列は `expr::type AS name` の形でだけ受け付け、
/// NULL 可否は cast の直後の marker `!`（`expr::type! AS name`）で書き手が主張する。
///
/// WhyNot: 式の型と NULL 可否を推論しないのは、PG の関数の戻り型表（`count` は NOT NULL、`max` は NULL 可、…）を
/// 持ち込むことになるから。型は cast で SQL 側に明示し、NULL 可否は書き手が `!` で主張して、実行時の decode が検証する
/// （NULL が来れば `DbErr.decodeError`。黙って既定値にはしない）。
///
pub mod Sqlfx.Q.QResolve {

    use Sqlfx.Q.QCte
    use Sqlfx.Q.QRender
    use Sqlfx.Q.QueryDef
    use Sqlfx.Q.Schema
    use Sqlfx.Q.SqlTokens
    use Sqlfx.Q.SqlType

    use Sqlfx.Q.Schema.Schema
    use Sqlfx.Q.Schema.Table
    use Sqlfx.Q.Schema.Column
    use Sqlfx.Q.SqlType.SqlType
    use Sqlfx.Q.QueryDef.Query
    use Sqlfx.Q.QueryDef.Shape
    use Sqlfx.Q.QueryDef.SlotKind

    pub enum ResolveError with Eq, Order, ToString {
        /// (クエリ名, テーブル名)
        case UnknownTable(String, String)
        /// (クエリ名, 列名)
        case UnknownColumn(String, String)
        /// (クエリ名, 列名) 複数のテーブルにある
        case AmbiguousColumn(String, String)
        /// (クエリ名, 列名) スキーマの型がこのライブラリに無い
        case UnsupportedColumnType(String, String)
        /// (クエリ名, 式) 型が決められない。`::type AS name` を書く
        case UntypedColumn(String, String)
        /// (クエリ名, 式) NOT NULL の marker `!` が `::type` の直後に無い。`expr::bigint! AS name` の形に直す
        case MisplacedNotNullMark(String, String)
        /// (クエリ名, 先頭の語) one / many は SELECT か RETURNING 付きの書き込み、exec は RETURNING 無しの書き込みだけ
        case UnsupportedStatement(String, String)
        /// (クエリ名, 列名) keyed の列が結果に無い
        case KeyedNotInResult(String, String)
        /// (クエリ名, slot 名, テーブル名) slot のテーブルが、その slot を含む文の FROM に無い
        case SlotTableNotInStatement(String, String, String)
        /// (クエリ名, slot 名) Changes は exec にだけ置ける
        case ChangesSlotRequiresExec(String, String)
        /// (クエリ名, slot 名, テーブル名) Changes のテーブルが UPDATE の対象でない
        case ChangesSlotNotUpdateTarget(String, String, String)
        /// (クエリ名, CTE 名) WITH RECURSIVE
        case RecursiveCte(String, String)
        /// (クエリ名) CTE の本文か副問い合わせの中の WITH
        case NestedWith(String)
        /// (クエリ名, CTE 名) 同じ名前の CTE が 2 つ
        case DuplicateCte(String, String)
        /// (クエリ名, CTE 名) 表と同じ名前の CTE
        case CteShadowsTable(String, String)
        /// (クエリ名) main という名前の CTE
        case ReservedCteName(String)
        /// (クエリ名, CTE 名, 並べた数, 文が返す数) CTE のカラムの並びの数が合わない
        case CteColumnCount(String, String, Int32, Int32)
        /// (クエリ名, CTE 名) RETURNING の無い書き込みの CTE を FROM で読んだ
        case CteWithoutReturning(String, String)
        /// (クエリ名, 表, 先の文, 後の文) 同じ表を 2 つの文で書く
        case SameTableWrittenTwice(String, String, String, String)
        /// (クエリ名, slot 名) WITH を含む query の Changes
        case ChangesSlotWithCte(String, String)
    }

    ///
    /// エラーを、規則・受け取った値・直し方の分かる 1 line にする。
    ///
    pub def describe(error: ResolveError): String = match error {
        case ResolveError.UnknownTable(queryName, table) => "query ${queryName} reads table ${table}, which is not in the migrations (or is a CTE defined later). Create the table, fix the name, or move the CTE before the one that reads it"
        case ResolveError.UnknownColumn(queryName, column) => "query ${queryName} reads column ${column}, which none of its tables has. Fix the name, or add the column in a migration"
        case ResolveError.AmbiguousColumn(queryName, column) => "column ${column} of query ${queryName} is in more than one of its tables. Qualify it with the table or its label"
        case ResolveError.UnsupportedColumnType(queryName, column) => "column ${column} of query ${queryName} has a type the generator does not map. Cast it, like ${column}::text AS ${column}"
        case ResolveError.UntypedColumn(queryName, expression) => "the type of `${expression}` in query ${queryName} is not known. Write it as `expr::type AS name`"
        case ResolveError.MisplacedNotNullMark(queryName, expression) => "the NOT NULL mark `!` in `${expression}` of query ${queryName} is not right after a cast. Write it as `expr::type! AS name`"
        case ResolveError.UnsupportedStatement(queryName, word) => "query ${queryName} starts its statement with ${word}, which does not fit its shape: one / many take a SELECT or a write with RETURNING, exec takes a write without RETURNING"
        case ResolveError.KeyedNotInResult(queryName, column) => "query ${queryName} is keyed(${column}), but ${column} is not in its result. Select the column, or fix the name in keyed(...)"
        case ResolveError.SlotTableNotInStatement(queryName, slot, table) => "slot ${slot} of query ${queryName} is Pred[${table}], but ${table} is not in the FROM of the statement that holds {${slot}}"
        case ResolveError.ChangesSlotRequiresExec(queryName, slot) => "slot ${slot} of query ${queryName} is Changes, which only an exec query can hold. Make the query exec"
        case ResolveError.ChangesSlotNotUpdateTarget(queryName, slot, table) => "slot ${slot} of query ${queryName} is Changes[${table}], but ${table} is not the table the UPDATE writes. Name the UPDATE's table in Changes[...]"
        case ResolveError.RecursiveCte(queryName, cte) => "query ${queryName} uses WITH RECURSIVE (CTE ${cte}), which the generator does not type. Put the recursive part in a SQL function and SELECT from it, or run it with RawSql"
        case ResolveError.NestedWith(queryName) => "query ${queryName} has a WITH inside a CTE or a subquery. The generator reads only the WITH at the start of the query; move the inner CTEs up into it"
        case ResolveError.DuplicateCte(queryName, cte) => "query ${queryName} defines CTE ${cte} twice. Rename one of them"
        case ResolveError.CteShadowsTable(queryName, cte) => "CTE ${cte} in query ${queryName} has the name of a table. Rename the CTE: PostgreSQL reads FROM ${cte} as the CTE but UPDATE ${cte} as the table, and the scope check needs one meaning"
        case ResolveError.ReservedCteName(queryName) => "query ${queryName} names a CTE main, which is how // unscoped: points at the main statement. Rename the CTE"
        case ResolveError.CteColumnCount(queryName, cte, declared, actual) => "CTE ${cte} in query ${queryName} names ${declared} columns, but its statement returns ${actual}. Make the list after the CTE name match the statement's columns"
        case ResolveError.CteWithoutReturning(queryName, cte) => "query ${queryName} reads CTE ${cte}, which writes without RETURNING, so it has no columns. Add RETURNING <columns> to CTE ${cte}"
        case ResolveError.SameTableWrittenTwice(queryName, table, first, second) => "query ${queryName} writes table ${table} in both ${first} and ${second}. PostgreSQL applies only one of two changes to the same row in one statement (the manual, 7.8.4), so one of them would be lost without an error. Merge them into one statement, or split the query"
        case ResolveError.ChangesSlotWithCte(queryName, slot) => "slot ${slot} of query ${queryName} is Changes, which cannot be used in a query with WITH: when the changes are empty the whole statement is skipped, and so are the other CTEs' writes. Split the query"
    }

    ///
    /// 結果の列 1 つ。
    ///
    pub type alias ResultColumn = { name = String, columnType = SqlType, nullable = Bool }

    ///
    /// 解決済みのクエリ。exec なら columns は Nil。`writes` は INSERT / UPDATE / DELETE（RETURNING 付きも）。
    ///
    pub type alias Resolved = { queryDef = Query, columns = List[ResultColumn], writes = Bool }

    ///
    /// 文の種類。列を決める語の列（SELECT リスト、または RETURNING の後ろ）を持つ。
    ///
    enum StatementKind {
        case Select(List[String])
        case Write
        case WriteReturning(List[String])
    }

    ///
    /// FROM / JOIN に出たテーブル。LEFT / FULL JOIN の相手は列が NULL になりうる。
    ///
    type alias Source = { table = Table, label = String, nullable = Bool }

    pub def resolve(schema: Schema, queryDef: Query): Result[ResolveError, Resolved] =
        let (sql, _) = QRender.toAnnotatedSql(queryDef);
        let words = SqlTokens.tokenize(sql);
        forM (
            statement <- QCte.split(words) |> Result.mapErr(cteError(queryDef#name));
            resolved <- if (List.isEmpty(statement#ctes)) resolvePlain(schema, queryDef, words) else resolveWith(schema, queryDef, statement)
        ) yield resolved

    ///
    /// WITH の無い query。
    ///
    def resolvePlain(schema: Schema, queryDef: Query, words: List[String]): Result[ResolveError, Resolved] =
        let firstWord = List.head(words) |> Option.getWithDefault("") |> String.toUpperCase;
        forM (
            resolution <- resolveStatement(queryDef#name, schema, words);
            _ <- if (shapeFits(queryDef#shape, resolution#kind)) Ok(()) else Err(ResolveError.UnsupportedStatement(queryDef#name, firstWord));
            _ <- checkKeyed(queryDef, resolution#columns);
            _ <- checkSlots(queryDef, _ -> resolution#sources);
            _ <- checkChangesSlots(queryDef, firstWord, resolution#sources)
        ) yield { queryDef = queryDef, columns = resolution#columns, writes = isWrite(resolution#kind) }

    ///
    /// 1 つの文を解決した結果。
    ///
    type alias Resolution = { kind = StatementKind, sources = List[Source], columns = List[ResultColumn] }

    ///
    /// 1 つの文（CTE の本文か本文）を解決する。書き込みの RETURNING は、PG と同じく INSERT なら書き込み先だけ、
    /// UPDATE / DELETE なら書き込み先と FROM / USING の後ろから引く。
    ///
    def resolveStatement(queryName: String, schema: Schema, words: List[String]): Result[ResolveError, Resolution] =
        let firstWord = List.head(words) |> Option.getWithDefault("") |> String.toUpperCase;
        forM (
            kind <- classifyStatement(words) |> Option.toOk(ResolveError.UnsupportedStatement(queryName, firstWord));
            sources <- collectSources(queryName, schema, words);
            columns <- match kind {
                case StatementKind.Select(listWords) => resolveColumnList(queryName, sources, listWords)
                case StatementKind.WriteReturning(listWords) => resolveColumnList(queryName, returningSources(firstWord, sources), listWords)
                case StatementKind.Write => Ok(Nil)
            }
        ) yield { kind = kind, sources = sources, columns = columns }

    def returningSources(firstWord: String, sources: List[Source]): List[Source] =
        if (firstWord == "INSERT") List.take(1, sources) else sources

    ///
    /// WITH を含む query。CTE を前から 1 つずつ、それより前の CTE を仮想の表にしたスキーマで解決し、最後に本文を解決する。
    ///
    def resolveWith(schema: Schema, queryDef: Query, statement: QCte.Statement): Result[ResolveError, Resolved] =
        let name = queryDef#name;
        let firstWord = List.head(statement#main#words) |> Option.getWithDefault("") |> String.toUpperCase;
        forM (
            _ <- checkCteNames(name, schema, statement#ctes);
            _ <- queryDef#slots |> List.find(slot -> slot#kind == SlotKind.Changes) |> Option.map(slot -> ResolveError.ChangesSlotWithCte(name, slot#name)) |> toErr;
            done <- Result.foldLeftM(resolveCte(name), { schema = schema, withoutReturning = Nil, statements = Nil }, statement#ctes);
            _ <- readsWithoutReturning(name, done#withoutReturning, statement#main#words);
            mainKind <- classifyStatement(statement#main#words) |> Option.toOk(ResolveError.UnsupportedStatement(name, firstWord));
            mainSources <- collectSources(name, done#schema, statement#main#words);
            // 同じ表を 2 つの文で書く件は、本文の列の解決より先に出す（本文が SELECT 1 のような形でも、先に気づかせたいのはこちら）
            _ <- sameTableWrittenTwice(name, List.reverse(done#statements) ::: ("main", statement#main, { kind = mainKind, sources = mainSources, columns = Nil }) :: Nil);
            main <- resolveStatement(name, done#schema, statement#main#words);
            _ <- if (shapeFits(queryDef#shape, main#kind)) Ok(()) else Err(ResolveError.UnsupportedStatement(name, firstWord));
            _ <- checkKeyed(queryDef, main#columns);
            _ <- checkSlots(queryDef, position -> sourcesAt(position, List.reverse(done#statements) ::: ("main", statement#main, main) :: Nil))
        ) yield {
            queryDef = queryDef,
            columns = main#columns,
            writes = isWrite(main#kind) or List.exists(match (_, _, resolution) -> isWrite(resolution#kind), done#statements)
        }

    ///
    /// CTE を解決していく途中の状態。`statements` は解決した CTE（名前, 位置, 結果。逆順）。
    ///
    type alias CteState = { schema = Schema, withoutReturning = List[String], statements = List[(String, QCte.Part, Resolution)] }

    ///
    /// CTE を 1 つ解決して、仮想の表として足す。RETURNING の無い書き込みの CTE はカラム 0 個の表にし、読まれた所で断る。
    ///
    def resolveCte(queryName: String, state: CteState, cte: QCte.Cte): Result[ResolveError, CteState] =
        forM (
            _ <- readsWithoutReturning(queryName, state#withoutReturning, cte#body#words);
            resolution <- resolveStatement(queryName, state#schema, cte#body#words);
            columns <- renameCteColumns(queryName, cte, resolution#columns)
        ) yield {
            let table = { name = cte#name, columns = List.map(column -> { name = column#name, columnType = Some(column#columnType), nullable = column#nullable }, columns), constraints = Nil };
            let silent = match resolution#kind { case StatementKind.Write => cte#name :: state#withoutReturning case _ => state#withoutReturning };
            { schema = Schema.addTable(table, state#schema), withoutReturning = silent, statements = (cte#name, cte#body, resolution) :: state#statements }
        }

    ///
    /// `WITH w(a, b) AS (…)` のカラムの並びで、位置ごとに名前を付け替える。数が違えば CteColumnCount。
    ///
    def renameCteColumns(queryName: String, cte: QCte.Cte, columns: List[ResultColumn]): Result[ResolveError, List[ResultColumn]] =
        match cte#columns {
            case None => Ok(columns)
            case Some(names) if List.length(names) != List.length(columns) => Err(ResolveError.CteColumnCount(queryName, cte#name, List.length(names), List.length(columns)))
            case Some(names) => Ok(List.zip(names, columns) |> List.map(match (renamed, column) -> { name = renamed | column }))
        }

    ///
    /// CTE の名前: 同じ名前が 2 つ、表の名前と同じ、`main`（`// unscoped:` で本文を指す語）を断る。
    ///
    def checkCteNames(queryName: String, schema: Schema, ctes: List[QCte.Cte]): Result[ResolveError, Unit] =
        let names = List.map(cte -> cte#name, ctes);
        let duplicate = names |> List.zipWithIndex |> List.find(match (index, cteName) -> List.memberOf(cteName, List.take(index, names))) |> Option.map(snd);
        match (duplicate, List.find(cteName -> Option.nonEmpty(Schema.findTable(cteName, schema)), names), List.memberOf("main", names)) {
            case (Some(cteName), _, _) => Err(ResolveError.DuplicateCte(queryName, cteName))
            case (_, Some(cteName), _) => Err(ResolveError.CteShadowsTable(queryName, cteName))
            case (_, _, true) => Err(ResolveError.ReservedCteName(queryName))
            case _ => Ok(())
        }

    ///
    /// RETURNING の無い書き込みの CTE を FROM / JOIN で読んでいれば CteWithoutReturning（深さを問わない）。
    ///
    /// WhyNot: カラム 0 個の表として黙って通さないのは、`*` で読むと空になるだけで気づけないため。
    ///
    def readsWithoutReturning(queryName: String, withoutReturning: List[String], words: List[String]): Result[ResolveError, Unit] =
        List.zip(words, List.drop(1, words))
            |> List.find(match (keyword, cteName) -> List.memberOf(String.toUpperCase(keyword), List#{"FROM", "JOIN"}) and List.memberOf(String.toLowerCase(cteName), withoutReturning))
            |> Option.map(match (_, cteName) -> ResolveError.CteWithoutReturning(queryName, String.toLowerCase(cteName)))
            |> toErr

    ///
    /// 書き込みの文を並べ、書き込み先の表が 2 つ以上の文で重なれば SameTableWrittenTwice。
    ///
    def sameTableWrittenTwice(queryName: String, statements: List[(String, QCte.Part, Resolution)]): Result[ResolveError, Unit] =
        let targets = statements |> List.filterMap(match (label, _, resolution) ->
            if (isWrite(resolution#kind)) List.head(resolution#sources) |> Option.map(source -> (source#table#name, label)) else None);
        targets
            |> List.zipWithIndex
            |> List.findMap(match (index, (table, label)) ->
                List.take(index, targets) |> List.find(match (earlier, _) -> earlier == table) |> Option.map(match (_, first) -> ResolveError.SameTableWrittenTwice(queryName, table, first, label)))
            |> toErr

    ///
    /// 語の位置を含む文の FROM の表。slot の置き文字の位置から、その slot を含む文を決めるのに使う。
    ///
    def sourcesAt(position: Int32, statements: List[(String, QCte.Part, Resolution)]): List[Source] =
        statements
            |> List.find(match (_, part, _) -> part#start <= position and position <= part#end)
            |> Option.map(match (_, _, resolution) -> resolution#sources)
            |> Option.getWithDefault(Nil)

    def cteError(queryName: String, error: QCte.CteError): ResolveError = match error {
        case QCte.CteError.RecursiveCte(cteName) => ResolveError.RecursiveCte(queryName, cteName)
        case QCte.CteError.NestedWith => ResolveError.NestedWith(queryName)
        case QCte.CteError.Unexpected(detail) => ResolveError.UnsupportedStatement(queryName, "WITH (${detail})")
    }

    def toErr(error: Option[ResolveError]): Result[ResolveError, Unit] = match error {
        case Some(e) => Err(e)
        case None => Ok(())
    }

    ///
    /// 先頭の語で種類を決める。書き込みは深さ 0 に RETURNING があれば列を返す。
    ///
    def classifyStatement(words: List[String]): Option[StatementKind] =
        match List.head(words) |> Option.map(String.toUpperCase) {
            case Some("SELECT") => Some(StatementKind.Select(selectListWords(words)))
            case Some("INSERT") => Some(writeKind(words))
            case Some("UPDATE") => Some(writeKind(words))
            case Some("DELETE") => Some(writeKind(words))
            case _ => None
        }

    def writeKind(words: List[String]): StatementKind =
        match SqlTokens.indexOfTopLevel("RETURNING", words) {
            case Some(index) => StatementKind.WriteReturning(List.drop(index + 1, words))
            case None => StatementKind.Write
        }

    ///
    /// SELECT [DISTINCT] と深さ 0 の FROM の間。
    ///
    def selectListWords(words: List[String]): List[String] =
        let afterSelect = List.drop(1, words) |> dropDistinct;
        match SqlTokens.indexOfTopLevel("FROM", afterSelect) {
            case Some(index) => List.take(index, afterSelect)
            case None => afterSelect
        }

    ///
    /// one / many は列を返す文、exec は返さない文にだけ付けられる。
    ///
    def shapeFits(shape: Shape, kind: StatementKind): Bool =
        match (shape, kind) {
            case (Shape.Exec, StatementKind.Write) => true
            case (Shape.Exec, _) => false
            case (_, StatementKind.Write) => false
            case _ => true
        }

    def isWrite(kind: StatementKind): Bool =
        match kind {
            case StatementKind.Select(_) => false
            case _ => true
        }

    // ---- FROM ----

    ///
    /// FROM / JOIN / UPDATE / INSERT INTO / DELETE FROM の後ろのテーブルを集める。カンマ区切りの FROM も追う。
    ///
    def collectSources(queryName: String, schema: Schema, words: List[String]): Result[ResolveError, List[Source]] =
        let deleting = List.head(words) |> Option.exists(word -> String.toUpperCase(word) == "DELETE");
        sourceLoop(queryName, schema, if (deleting) markUsing(words) else words, Nil, "", 0)

    ///
    /// DELETE の深さ 0 の USING を FROM と同じに読むため、印の語に置き換える。JOIN ... USING (col) の USING は触らない（深さ 0 でも `(` が続く）。
    ///
    def markUsing(words: List[String]): List[String] =
        let (marked, _) = List.foldLeft((acc, pair) -> {
            let (done, depth) = acc;
            let (word, next) = pair;
            let nextDepth = if (word == "(") depth + 1 else if (word == ")") depth - 1 else depth;
            if (depth == 0 and String.toUpperCase(word) == "USING" and next != "(") ("FROM" :: done, nextDepth) else (word :: done, nextDepth)
        }, (Nil, 0), List.zip(words, List.drop(1, words) ::: "" :: Nil));
        List.reverse(marked)

    ///
    /// `previous` は 1 つ前の語（大文字）。深さ 0 の FROM / JOIN / INTO / UPDATE の直後をテーブルとして読む。
    ///
    def sourceLoop(queryName: String, schema: Schema, words: List[String], acc: List[Source], previous: String, depth: Int32): Result[ResolveError, List[Source]] =
        match words {
            case Nil => Ok(List.reverse(acc))
            case "(" :: rest => sourceLoop(queryName, schema, rest, acc, "(", depth + 1)
            case ")" :: rest => sourceLoop(queryName, schema, rest, acc, ")", depth - 1)
            case word :: rest if depth == 0 and String.toUpperCase(word) == "OUTER" => sourceLoop(queryName, schema, rest, acc, previous, depth)
            case word :: rest if depth == 0 and isTableIntroducer(String.toUpperCase(word), previous) =>
                let upper = String.toUpperCase(word);
                let leftSideNullable = previous == "RIGHT" or previous == "FULL";
                let joined = if (leftSideNullable) List.map(source -> { table = source#table, label = source#label, nullable = true }, acc) else acc;
                readSource(queryName, schema, rest, joined, { nullable = previous == "LEFT" or previous == "FULL", functionAllowed = upper == "FROM" or upper == "JOIN" })
            case "," :: rest if depth == 0 and inFromClause(acc, previous) =>
                readSource(queryName, schema, rest, acc, { nullable = false, functionAllowed = true })
            case word :: rest => sourceLoop(queryName, schema, rest, acc, String.toUpperCase(word), depth)
        }

    ///
    /// テーブル名と label を読み、続きへ。`(` が来たらサブクエリ、`name (` なら関数（`unnest(:rows) AS v(a, b)`）で、
    /// どちらも列の分からない opaque な table source として飛ばす。列は解決しないので、その列を SELECT に出すなら `expr::type AS name` で書く。
    ///
    /// WhyNot: 関数の列を引数の型（`jsonb[]` → `jsonb`）から引かないのは、`unnest` の多引数形や `WITH ORDINALITY`、
    /// `jsonb_to_recordset(...) AS x(a int, b text)` の列定義まで読む本格版になり、FROM を読む範囲がサブクエリと不揃いになるため。
    ///
    /// `functionAllowed` は FROM / JOIN の後ろだけ true。`INSERT INTO users (name)` の `(` は列の並びで、関数ではない。
    ///
    def readSource(queryName: String, schema: Schema, words: List[String], acc: List[Source], mode: { nullable = Bool, functionAllowed = Bool }): Result[ResolveError, List[Source]] =
        match words {
            case "(" :: _ => sourceLoop(queryName, schema, words, acc, "SUBQUERY", 0)
            case name :: "(" :: rest if mode#functionAllowed and isIdentifier(name) => sourceLoop(queryName, schema, "(" :: rest, acc, "SUBQUERY", 0)
            case name :: rest =>
                let (label, afterAlias) = readAlias(rest);
                match (match Schema.findTable(name, schema) { case Some(found) => Some(found) case None => Schema.findTable(String.toLowerCase(name), schema) }) {
                    case Some(table) => sourceLoop(queryName, schema, afterAlias, { table = table, label = label, nullable = mode#nullable } :: acc, "SOURCE", 0)
                    case None => Err(ResolveError.UnknownTable(queryName, name))
                }
            case Nil => Ok(List.reverse(acc))
        }

    ///
    /// `[AS] label`。キーワードなら label 無し。
    ///
    def readAlias(words: List[String]): (String, List[String]) =
        match words {
            case "AS" :: label :: rest => (label, rest)
            case "as" :: label :: rest => (label, rest)
            case label :: rest if isIdentifier(label) and not isKeyword(String.toUpperCase(label)) => (label, rest)
            case _ => ("", words)
        }

    ///
    /// `UPDATE` は文の先頭だけ。`ON CONFLICT DO UPDATE SET` の UPDATE は次が SET で、テーブルではない。
    ///
    def isTableIntroducer(upper: String, previous: String): Bool =
        upper == "FROM" or upper == "JOIN" or (upper == "UPDATE" and previous == "") or (upper == "INTO" and previous == "INSERT")

    ///
    /// 直前がテーブル（label 込み）を読み終えた所なら、カンマは次のテーブル。
    ///
    def inFromClause(acc: List[Source], previous: String): Bool =
        previous == "SOURCE" and not List.isEmpty(acc)

    def isKeyword(upper: String): Bool =
        List.memberOf(upper, List#{"NATURAL", "LATERAL", "ONLY", "DEFAULT", "TABLESAMPLE", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "ON", "USING", "GROUP", "ORDER", "LIMIT", "OFFSET", "HAVING", "UNION", "SET", "RETURNING", "VALUES", "AND", "OR", "NOT", "AS", "FOR", "WINDOW"})

    def isIdentifier(word: String): Bool =
        match String.toList(word) {
            case ch :: _ => Char.isLetter(ch) or ch == '_'
            case Nil => false
        }

    // ---- SELECT リスト ----

    ///
    /// 列を決める語の列（SELECT リストか RETURNING の後ろ）をカンマで切り、1 つずつ列にする。
    ///
    def resolveColumnList(queryName: String, sources: List[Source], listWords: List[String]): Result[ResolveError, List[ResultColumn]] =
        SqlTokens.splitTopLevel(",", listWords)
            |> List.traverse(item -> resolveItem(queryName, sources, item))
            |> Result.map(List.flatten)

    def dropDistinct(words: List[String]): List[String] =
        match words {
            case word :: rest if String.toUpperCase(word) == "DISTINCT" => rest
            case _ => words
        }

    ///
    /// リストの 1 項目。`*` / `t.*` / `col` / `t.col` / `col::type` / `expr::type AS name` / `col AS name`。
    /// `::type!` の marker は cast の直後にだけ置ける。それ以外の位置（`count(*)!`、`id!`、`bigint !`）は MisplacedNotNullMark。
    ///
    /// WhyNot: cast の無い式に `!` を許さないのは、cast が無いと型が決まらず、marker は NULL 可否しか言わないから。
    /// 列参照（`id!`）にも許さないのは、marker の綴りを `::type!` の 1 つに固定して、`id!` と `id::bigint!` の 2 通りを作らないため。
    ///
    def resolveItem(queryName: String, sources: List[Source], item: List[String]): Result[ResolveError, List[ResultColumn]] =
        match item {
            case "*" :: Nil => Ok(List.flatMap(allColumns, sources))
            case label :: "." :: "*" :: Nil => Ok(List.filter(source -> source#label == label or source#table#name == label, sources) |> List.flatMap(allColumns))
            case _ =>
                let (annotated, label) = splitAlias(item);
                let (expression, asserted) = splitNotNullMark(annotated);
                let misplaced = ResolveError.MisplacedNotNullMark(queryName, List.join(" ", annotated));
                match expression {
                    case Nil => Err(ResolveError.UntypedColumn(queryName, List.join(" ", item)))
                    case _ if List.last(expression) == Some("!") => Err(misplaced)
                    case ref :: "::" :: castType => castColumn(queryName, sources, ref, castType, label, asserted)
                    case _ =>
                        match List.reverse(expression) {
                            case castType :: "::" :: rest if not List.isEmpty(rest) =>
                                castExpression(queryName, List.reverse(rest), castType, label, asserted)
                            case _ if asserted => Err(misplaced)
                            case _ => plainColumn(queryName, sources, expression, label)
                        }
                }
        }

    ///
    /// 末尾の `AS name` か、式の後ろに置いた名前を切り離す。
    ///
    def splitAlias(item: List[String]): (List[String], Option[String]) =
        match List.reverse(item) {
            case label :: "AS" :: rest => (List.reverse(rest), Some(label))
            case label :: "as" :: rest => (List.reverse(rest), Some(label))
            case label :: before :: rest if isIdentifier(label) and isIdentifier(before) and not isKeyword(String.toUpperCase(label)) and not isKeyword(String.toUpperCase(before)) and before != "." =>
                (List.reverse(before :: rest), Some(label))
            case _ => (item, None)
        }

    ///
    /// 末尾の語に付いた NOT NULL の marker（`bigint!`）を外し、付いていたかを返す。
    ///
    def splitNotNullMark(expression: List[String]): (List[String], Bool) =
        match List.reverse(expression) {
            case last :: rest if String.endsWith(suffix = "!", last) and last != "!" =>
                (List.reverse(String.dropRight(1, last) :: rest), true)
            case _ => (expression, false)
        }

    ///
    /// `col` / `t.col`。
    ///
    def plainColumn(queryName: String, sources: List[Source], expression: List[String], label: Option[String]): Result[ResolveError, List[ResultColumn]] =
        match expression {
            case name :: Nil => lookup(queryName, sources, None, name) |> Result.map(column -> List#{rename(label, column)})
            case qualifier :: "." :: name :: Nil => lookup(queryName, sources, Some(qualifier), name) |> Result.map(column -> List#{rename(label, column)})
            case _ => Err(ResolveError.UntypedColumn(queryName, List.join(" ", expression)))
        }

    ///
    /// `col::type` / `col::type!`。列が解決できれば NULL 可否は列の物、名前は label か列名。`!` が付けば NOT NULL。
    ///
    /// WhyNot: DDL が NOT NULL の列に `!` が付いても弾かないのは、LEFT JOIN の相手や WHERE で NULL を除いた列を
    /// NOT NULL と主張する経路と同じ綴りだから。DDL と marker のどちらかが NOT NULL と言えば NOT NULL で、decode が検証する。
    ///
    def castColumn(queryName: String, sources: List[Source], ref: String, castType: List[String], label: Option[String], asserted: Bool): Result[ResolveError, List[ResultColumn]] =
        forM (
            sqlType <- parseCast(queryName, castType);
            column <- lookup(queryName, sources, None, ref)
        ) yield List#{ { name = Option.getWithDefault(column#name, label), columnType = sqlType, nullable = column#nullable and not asserted } }

    ///
    /// `expr::type AS name` / `expr::type! AS name`。名前は必須。NULL 可否は `!` が無ければ true（関数の型表を持たない）、あれば false。
    ///
    def castExpression(queryName: String, expression: List[String], castType: String, label: Option[String], asserted: Bool): Result[ResolveError, List[ResultColumn]] =
        forM (
            sqlType <- parseCast(queryName, List#{castType});
            name <- label |> Option.toOk(ResolveError.UntypedColumn(queryName, List.join(" ", expression)))
        ) yield List#{ { name = name, columnType = sqlType, nullable = not asserted } }

    def parseCast(queryName: String, castType: List[String]): Result[ResolveError, SqlType] =
        let spelling = List.join(" ", castType) |> String.toLowerCase;
        SqlType.fromPgName(spelling) |> Option.toOk(ResolveError.UntypedColumn(queryName, "::${spelling}"))

    def rename(label: Option[String], column: ResultColumn): ResultColumn =
        { name = Option.getWithDefault(column#name, label), columnType = column#columnType, nullable = column#nullable }

    ///
    /// 列名を FROM のテーブルから引く。qualifier があればその label かテーブル名だけ、無ければ全部を見て 1 つだけ合うこと。
    ///
    def lookup(queryName: String, sources: List[Source], qualifier: Option[String], name: String): Result[ResolveError, ResultColumn] =
        let candidates = sources
            |> List.filter(source -> match qualifier {
                case Some(q) => source#label == q or source#table#name == q
                case None => true
            })
            |> List.filterMap(source -> Schema.findColumn(name, source#table) |> Option.map(column -> (source, column)));
        match candidates {
            case (source, column) :: Nil => toResultColumn(queryName, source, column)
            case Nil => Err(ResolveError.UnknownColumn(queryName, name))
            case _ => Err(ResolveError.AmbiguousColumn(queryName, name))
        }

    def allColumns(source: Source): List[ResultColumn] =
        source#table#columns
            |> List.filterMap(column -> column#columnType |> Option.map(sqlType -> { name = column#name, columnType = sqlType, nullable = column#nullable or source#nullable }))

    def toResultColumn(queryName: String, source: Source, column: Column): Result[ResolveError, ResultColumn] =
        column#columnType
            |> Option.map(sqlType -> { name = column#name, columnType = sqlType, nullable = column#nullable or source#nullable })
            |> Option.toOk(ResolveError.UnsupportedColumnType(queryName, column#name))

    // ---- keyed / slot ----

    def checkKeyed(queryDef: Query, columns: List[ResultColumn]): Result[ResolveError, Unit] =
        match queryDef#keyed {
            case Some(key) if not List.exists(column -> column#name == key, columns) => Err(ResolveError.KeyedNotInResult(queryDef#name, key))
            case _ => Ok(())
        }

    ///
    /// slot の表が、その `{slot}` を含む文の FROM に在るか。`sourcesAt` は slot の置き文字の位置 → その文の表。
    ///
    def checkSlots(queryDef: Query, sourcesAt: Int32 -> List[Source]): Result[ResolveError, Unit] =
        let positions = QRender.slotPositions(queryDef);
        queryDef#slots
            |> List.find(slot -> {
                let position = List.find(match (slotName, _) -> slotName == slot#name, positions) |> Option.map(snd) |> Option.getWithDefault(0);
                not List.exists(source -> source#table#name == slot#table, sourcesAt(position))
            })
            |> Option.map(slot -> ResolveError.SlotTableNotInStatement(queryDef#name, slot#name, slot#table))
            |> (missing -> match missing { case Some(e) => Err(e) case None => Ok(()) })

    ///
    /// Changes は exec の UPDATE で、UPDATE 直後のテーブル（sources の先頭）にだけ置ける。
    /// FROM のどれかに一致するだけでは `UPDATE posts ... FROM users` に `Changes[users]` が通ってしまう。
    ///
    def checkChangesSlots(queryDef: Query, firstWord: String, sources: List[Source]): Result[ResolveError, Unit] =
        let target = if (firstWord == "UPDATE") List.head(sources) |> Option.map(source -> source#table#name) else None;
        queryDef#slots
            |> List.filter(slot -> slot#kind == SlotKind.Changes)
            |> List.findMap(slot ->
                if (queryDef#shape != Shape.Exec) Some(ResolveError.ChangesSlotRequiresExec(queryDef#name, slot#name))
                else if (target != Some(slot#table)) Some(ResolveError.ChangesSlotNotUpdateTarget(queryDef#name, slot#name, slot#table))
                else None)
            |> (failure -> match failure { case Some(e) => Err(e) case None => Ok(()) })

}
