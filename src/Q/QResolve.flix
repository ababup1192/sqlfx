///
/// `.q` の SQL を机上のスキーマに当てて、結果の列（名前・型・NULL 可否）を決める。生成器はこの結果から型とデコーダを吐く。
/// 読むのは SELECT の FROM / JOIN とリストだけ。式の列は `expr::type AS name` の形でだけ受け付ける。
///
/// WhyNot: 式の型を推論しないのは、PG の関数の戻り型表を持ち込むことになるから。
/// キャストを書けば EXPLAIN に貼っても同じ意味で、型が SQL 側に明示される。
///
mod QResolve {

    use Schema.Schema
    use Schema.Table
    use Schema.Column
    use SqlType.SqlType
    use QueryDef.Query
    use QueryDef.Shape
    use QueryDef.SlotKind

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
        /// (クエリ名, 先頭の語) one / many は SELECT か RETURNING 付きの書き込み、exec は RETURNING 無しの書き込みだけ
        case UnsupportedStatement(String, String)
        /// (クエリ名, 列名) keyed の列が結果に無い
        case KeyedNotInResult(String, String)
        /// (クエリ名, slot 名, テーブル名) slot のテーブルが FROM に無い
        case SlotTableNotInFrom(String, String, String)
        /// (クエリ名, slot 名) Changes は exec にだけ置ける
        case ChangesSlotRequiresExec(String, String)
        /// (クエリ名, slot 名, テーブル名) Changes のテーブルが UPDATE の対象でない
        case ChangesSlotNotUpdateTarget(String, String, String)
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
        let (sql, _) = QRender.toSql(queryDef);
        let words = SqlTokens.tokenize(sql);
        let firstWord = List.head(words) |> Option.getWithDefault("") |> String.toUpperCase;
        let unsupported = ResolveError.UnsupportedStatement(queryDef#name, firstWord);
        forM (
            kind <- classifyStatement(words) |> Option.toOk(unsupported);
            _ <- if (shapeFits(queryDef#shape, kind)) Ok(()) else Err(unsupported);
            sources <- collectSources(queryDef#name, schema, words);
            columns <- match kind {
                case StatementKind.Select(listWords) => resolveColumnList(queryDef#name, sources, listWords)
                case StatementKind.WriteReturning(listWords) => resolveColumnList(queryDef#name, sources, listWords)
                case StatementKind.Write => Ok(Nil)
            };
            _ <- checkKeyed(queryDef, columns);
            _ <- checkSlots(queryDef, sources);
            _ <- checkChangesSlots(queryDef, firstWord, sources)
        ) yield { queryDef = queryDef, columns = columns, writes = isWrite(kind) }

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
        sourceLoop(queryName, schema, words, Nil, "", 0)

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
                let leftSideNullable = previous == "RIGHT" or previous == "FULL";
                let joined = if (leftSideNullable) List.map(source -> { table = source#table, label = source#label, nullable = true }, acc) else acc;
                readSource(queryName, schema, rest, joined, previous == "LEFT" or previous == "FULL")
            case "," :: rest if depth == 0 and inFromClause(acc, previous) =>
                readSource(queryName, schema, rest, acc, false)
            case word :: rest => sourceLoop(queryName, schema, rest, acc, String.toUpperCase(word), depth)
        }

    ///
    /// テーブル名と label を読み、続きへ。`(` が来たらサブクエリなので飛ばす（v1 では解決しない）。
    ///
    def readSource(queryName: String, schema: Schema, words: List[String], acc: List[Source], nullable: Bool): Result[ResolveError, List[Source]] =
        match words {
            case "(" :: _ => sourceLoop(queryName, schema, words, acc, "SUBQUERY", 0)
            case name :: rest =>
                let (label, afterAlias) = readAlias(rest);
                match Schema.findTable(name, schema) {
                    case Some(table) => sourceLoop(queryName, schema, afterAlias, { table = table, label = label, nullable = nullable } :: acc, "SOURCE", 0)
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
    ///
    def resolveItem(queryName: String, sources: List[Source], item: List[String]): Result[ResolveError, List[ResultColumn]] =
        match item {
            case "*" :: Nil => Ok(List.flatMap(allColumns, sources))
            case label :: "." :: "*" :: Nil => Ok(List.filter(source -> source#label == label or source#table#name == label, sources) |> List.flatMap(allColumns))
            case _ =>
                let (expression, label) = splitAlias(item);
                match expression {
                    case ref :: "::" :: castType => castColumn(queryName, sources, ref, castType, label)
                    case Nil => Err(ResolveError.UntypedColumn(queryName, List.join(" ", item)))
                    case _ =>
                        match List.reverse(expression) {
                            case castType :: "::" :: rest if not List.isEmpty(rest) =>
                                castExpression(queryName, List.reverse(rest), castType, label)
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
    /// `col` / `t.col`。
    ///
    def plainColumn(queryName: String, sources: List[Source], expression: List[String], label: Option[String]): Result[ResolveError, List[ResultColumn]] =
        match expression {
            case name :: Nil => lookup(queryName, sources, None, name) |> Result.map(column -> List#{rename(label, column)})
            case qualifier :: "." :: name :: Nil => lookup(queryName, sources, Some(qualifier), name) |> Result.map(column -> List#{rename(label, column)})
            case _ => Err(ResolveError.UntypedColumn(queryName, List.join(" ", expression)))
        }

    ///
    /// `col::type`。列が解決できれば NULL 可否は列の物、名前は label か列名。
    ///
    def castColumn(queryName: String, sources: List[Source], ref: String, castType: List[String], label: Option[String]): Result[ResolveError, List[ResultColumn]] =
        forM (
            sqlType <- parseCast(queryName, castType);
            column <- lookup(queryName, sources, None, ref)
        ) yield List#{ { name = Option.getWithDefault(column#name, label), columnType = sqlType, nullable = column#nullable } }

    ///
    /// `expr::type AS name`。名前は必須、NULL 可否は分からないので true。
    ///
    def castExpression(queryName: String, expression: List[String], castType: String, label: Option[String]): Result[ResolveError, List[ResultColumn]] =
        forM (
            sqlType <- parseCast(queryName, List#{castType});
            name <- label |> Option.toOk(ResolveError.UntypedColumn(queryName, List.join(" ", expression)))
        ) yield List#{ { name = name, columnType = sqlType, nullable = true } }

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

    def checkSlots(queryDef: Query, sources: List[Source]): Result[ResolveError, Unit] =
        queryDef#slots
            |> List.find(slot -> not List.exists(source -> source#table#name == slot#table, sources))
            |> Option.map(slot -> ResolveError.SlotTableNotInFrom(queryDef#name, slot#name, slot#table))
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
