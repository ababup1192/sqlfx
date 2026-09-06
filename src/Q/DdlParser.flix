///
/// migrations の DDL を読んで机上のスキーマを進める。読むのは CREATE TABLE / ALTER TABLE ADD|DROP COLUMN / DROP TABLE と、
/// 名前付きの制約（CONSTRAINT name ... / CREATE UNIQUE INDEX name）。それ以外は「読めない DDL」として警告に積む（design.md §3、PLAN フェーズ 2-2）。
///
/// 名前の無い UNIQUE / CHECK / FOREIGN KEY はエラーにする。違反が制約名で返るので、名前が無いと生成コードから参照できない。
/// PRIMARY KEY だけは名前が無くてもよい（生成コードの対象にしない）。
///
/// WhyNot: 本物の SQL パーサを書かないのは、スキーマ解決に要るのがテーブルと列と型だけだから。
/// 読めない文は落とさず警告にするので、トリガや関数を含む migration でも生成は止まらない。
///
mod DdlParser {

    use Schema.Schema
    use Schema.Column
    use Schema.Constraint
    use Schema.ConstraintKind
    use SqlType.SqlType

    ///
    /// 読めた上で矛盾している DDL。無いテーブルへの ALTER など。
    ///
    pub enum DdlError with Eq, Order, ToString {
        /// (文, テーブル名)
        case UnknownTable(String, String)
        /// (文, 列名)
        case UnknownColumn(String, String)
        /// CREATE TABLE の列定義が読めない（文）
        case Unreadable(String)
        /// 列定義の中の名前の無い UNIQUE / CHECK / REFERENCES（文, 列名）。`CONSTRAINT name` を付けてもらう
        case UnnamedColumnConstraint(String, String)
        /// 名前の無いテーブル制約 UNIQUE / CHECK / FOREIGN KEY（文, テーブル名）
        case UnnamedTableConstraint(String, String)
    }

    ///
    /// DDL の文字列を文ごとに適用する。戻りは (進めたスキーマ, 読めなかった文の警告)。
    ///
    pub def apply(sql: String, schema: Schema): Result[DdlError, (Schema, List[String])] =
        splitStatements(sql)
            |> Result.foldLeftM((state, statement) -> {
                let (current, warnings) = state;
                applyStatement(statement, current) |> Result.map(next -> match next {
                    case (nextSchema, Some(warning)) => (nextSchema, warning :: warnings)
                    case (nextSchema, None) => (nextSchema, warnings)
                })
            }, (schema, Nil))
            |> Result.map(state -> { let (finalSchema, warnings) = state; (finalSchema, List.reverse(warnings)) })

    ///
    /// 1 文を適用する。戻りの Option は警告。
    ///
    def applyStatement(statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        let words = tokens(statement);
        let upper = List.map(String.toUpperCase, words);
        match upper {
            case "CREATE" :: "TABLE" :: "IF" :: "NOT" :: "EXISTS" :: _ => createTable(List.drop(5, words), statement, schema)
            case "CREATE" :: "TABLE" :: _ => createTable(List.drop(2, words), statement, schema)
            case "DROP" :: "TABLE" :: "IF" :: "EXISTS" :: _ => Ok((dropTables(List.drop(4, words), schema), None))
            case "DROP" :: "TABLE" :: _ => Ok((dropTables(List.drop(2, words), schema), None))
            case "ALTER" :: "TABLE" :: "ONLY" :: _ => alterTable(nth(3, words), List.drop(4, words), statement, schema)
            case "ALTER" :: "TABLE" :: _ => alterTable(nth(2, words), List.drop(3, words), statement, schema)
            case "CREATE" :: "INDEX" :: _ => Ok((schema, None))
            case "CREATE" :: "UNIQUE" :: "INDEX" :: _ => uniqueIndex(List.drop(3, words), statement, schema)
            case "DROP" :: "INDEX" :: _ => Ok((dropIndexes(List.drop(2, words), schema), None))
            case "ALTER" :: "INDEX" :: _ => Ok((renameIndex(List.drop(2, words), schema), None))
            case Nil => Ok((schema, None))
            case _ => Ok((schema, Some("unreadable DDL: ${List.take(3, words) |> List.join(" ")} ...")))
        }

    ///
    /// `CREATE TABLE name (列定義, ...)`。列定義は最上位のカンマで切り、制約だけの物は飛ばす。
    ///
    def createTable(afterKeyword: List[String], statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        let name = nth(0, afterKeyword) |> unquote;
        match (String.indexOf(substr = "(", statement), String.indexOfRight(substr = ")", statement)) {
            case (Some(open), Some(close)) if open < close =>
                let definitions = String.slice(start = open + 1, end = close, statement) |> splitTopLevel(',') |> List.map(String.trim);
                let (constraintDefinitions, columnDefinitions) = List.partition(isConstraint, definitions);
                forM (
                    parsedColumns <- List.traverse(definition -> parseColumnDefinition(definition, statement), columnDefinitions);
                    tableLevel <- List.traverse(definition -> tableConstraint(definition, statement, name), constraintDefinitions)
                ) yield {
                    let constraints = List.append(List.flatMap(snd, parsedColumns), List.filterMap(identity, tableLevel));
                    (Schema.addTable({ name = name, columns = List.map(fst, parsedColumns), constraints = constraints }, schema), None)
                }
            case _ => Err(DdlError.Unreadable(statement))
        }

    ///
    /// `CREATE UNIQUE INDEX [CONCURRENTLY] [IF NOT EXISTS] name ON table (...)`。違反はインデックス名で返るので UNIQUE 制約として持つ。
    ///
    def uniqueIndex(afterKeyword: List[String], statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        let words = List.dropWhile(word -> List.memberOf(String.toUpperCase(word), List#{"CONCURRENTLY", "IF", "NOT", "EXISTS"}), afterKeyword);
        match words {
            case rawName :: on :: rawTable :: _ if String.toUpperCase(on) == "ON" =>
                let table = unquote(rawTable);
                Schema.addConstraint(table, { name = unquote(rawName), kind = ConstraintKind.Unique }, schema)
                    |> Option.map(next -> (next, None))
                    |> Option.toOk(DdlError.UnknownTable(statement, table))
            case _ => Ok((schema, Some("unreadable DDL: CREATE UNIQUE INDEX ...")))
        }

    ///
    /// `DROP INDEX [CONCURRENTLY] [IF EXISTS] a, b`。テーブル名を持たないので、どのテーブルからでも消す。
    ///
    def dropIndexes(afterKeyword: List[String], schema: Schema): Schema =
        List.dropWhile(word -> List.memberOf(String.toUpperCase(word), List#{"CONCURRENTLY", "IF", "EXISTS"}), afterKeyword)
            |> List.takeWhile(word -> not List.memberOf(String.toUpperCase(word), List#{"CASCADE", "RESTRICT"}))
            |> List.filter(word -> word != ",")
            |> List.foldLeft((acc, rawName) -> Schema.dropConstraintAnywhere(unquote(rawName), acc), schema)

    ///
    /// `ALTER INDEX [IF EXISTS] old RENAME TO new`。それ以外の ALTER INDEX は制約に関係ないので無視。
    ///
    def renameIndex(afterKeyword: List[String], schema: Schema): Schema =
        let words = List.dropWhile(word -> List.memberOf(String.toUpperCase(word), List#{"IF", "EXISTS"}), afterKeyword);
        match List.map(String.toUpperCase, words) {
            case _ :: "RENAME" :: "TO" :: _ => Schema.renameConstraintAnywhere({ oldName = unquote(nth(0, words)), newName = unquote(nth(3, words)) }, schema)
            case _ => schema
        }

    ///
    /// 列定義 1 つを、列と、その中の名前付き制約に読む。
    ///
    def parseColumnDefinition(definition: String, statement: String): Result[DdlError, (Column, List[Constraint])] =
        forM (
            column <- parseColumn(definition) |> Option.toOk(DdlError.Unreadable(statement));
            inline <- inlineConstraints(definition, statement)
        ) yield (column, inline)

    ///
    /// 列定義の中の制約を全部拾う。`CONSTRAINT name UNIQUE|CHECK|REFERENCES` を積み、`CONSTRAINT name PRIMARY KEY|NOT NULL` は対象外で飛ばす。
    /// CONSTRAINT の直後以外に UNIQUE / CHECK / REFERENCES が出たら名前無しなのでエラー。括弧の中（CHECK の式、REFERENCES の列）は見ない。
    ///
    def inlineConstraints(definition: String, statement: String): Result[DdlError, List[Constraint]] =
        let words = tokens(definition);
        let column = nth(0, words) |> unquote;
        scanConstraints({ statement = statement, owner = column }, List.drop(1, words), 0, Nil) |> Result.map(List.reverse)

    ///
    /// 語を左から見て制約を積む。depth は括弧の深さ、acc は積んだ制約の逆順。
    ///
    def scanConstraints(context: { statement = String, owner = String }, words: List[String], depth: Int32, acc: List[Constraint]): Result[DdlError, List[Constraint]] =
        match words {
            case Nil => Ok(acc)
            case "(" :: rest => scanConstraints(context, rest, depth + 1, acc)
            case ")" :: rest => scanConstraints(context, rest, depth - 1, acc)
            case _ :: rest if depth > 0 => scanConstraints(context, rest, depth, acc)
            case word :: rawName :: kindWord :: rest if String.toUpperCase(word) == "CONSTRAINT" =>
                match constraintKindOf(String.toUpperCase(kindWord)) {
                    case Some(kind) => scanConstraints(context, rest, depth, { name = unquote(rawName), kind = kind } :: acc)
                    case None => scanConstraints(context, rest, depth, acc)
                }
            case word :: _ if Option.nonEmpty(constraintKindOf(String.toUpperCase(word))) => Err(DdlError.UnnamedColumnConstraint(context#statement, context#owner))
            case _ :: rest => scanConstraints(context, rest, depth, acc)
        }

    ///
    /// テーブル制約。`CONSTRAINT name UNIQUE|CHECK|FOREIGN KEY|PRIMARY KEY (...)`。名前無しの UNIQUE / CHECK / FOREIGN KEY はエラー、
    /// PRIMARY KEY と EXCLUDE は名前があってもなくても対象外（None）。
    ///
    def tableConstraint(definition: String, statement: String, table: String): Result[DdlError, Option[Constraint]] =
        let words = tokens(definition);
        match List.map(String.toUpperCase, words) {
            case "CONSTRAINT" :: _ :: kindWord :: _ =>
                Ok(constraintKindOf(kindWord) |> Option.map(kind -> { name = nth(1, words) |> unquote, kind = kind }))
            case kindWord :: _ if Option.nonEmpty(constraintKindOf(kindWord)) => Err(DdlError.UnnamedTableConstraint(statement, table))
            case _ => Ok(None)
        }

    ///
    /// 制約の先頭の語 → 種類。REFERENCES は列定義の中の FK。
    ///
    def constraintKindOf(upper: String): Option[ConstraintKind] = match upper {
        case "UNIQUE" => Some(ConstraintKind.Unique)
        case "CHECK" => Some(ConstraintKind.Check)
        case "FOREIGN" => Some(ConstraintKind.ForeignKey)
        case "REFERENCES" => Some(ConstraintKind.ForeignKey)
        case _ => None
    }

    ///
    /// `DROP TABLE a, b [CASCADE]`。名前をカンマ区切りで全部落とす。
    ///
    def dropTables(words: List[String], schema: Schema): Schema =
        words
            |> List.takeWhile(word -> not List.memberOf(String.toUpperCase(word), List#{"CASCADE", "RESTRICT"}))
            |> List.filter(word -> word != ",")
            |> List.foldLeft((acc, name) -> Schema.dropTable(unquote(name), acc), schema)

    ///
    /// `ADD [COLUMN] [IF NOT EXISTS] 定義` / `DROP [COLUMN] [IF EXISTS] 名前` /
    /// `ALTER [COLUMN] 名前 SET|DROP NOT NULL` / `ALTER [COLUMN] 名前 TYPE 型` / `RENAME [COLUMN] 旧 TO 新` /
    /// `ADD CONSTRAINT name ...` / `DROP CONSTRAINT name`。それ以外の ALTER は警告。
    ///
    /// WhyNot: ALTER COLUMN を警告で済ませないのは、NULL 可否や型が古いままのコードを吐くと実行時の decodeError になるから。
    ///
    def alterTable(rawName: String, action: List[String], statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        let name = unquote(rawName);
        let normalized = dropOptionalWords(List#{"COLUMN", "IF", "NOT", "EXISTS"}, action);
        let upper = List.map(String.toUpperCase, normalized);
        let unknownTable = DdlError.UnknownTable(statement, name);
        if (List.length(splitTopLevel(',', List.join(" ", action))) > 1)
            Ok((schema, Some("unreadable DDL: ALTER TABLE with several actions (split them): ${List.take(4, action) |> List.join(" ")} ...")))
        else match upper {
            case "ADD" :: word :: _ if isConstraintStart(word) =>
                tableConstraint(List.join(" ", List.drop(1, normalized)), statement, name)
                    |> Result.flatMap(found -> match found {
                        case Some(constraint) => Schema.addConstraint(name, constraint, schema) |> Option.toOk(unknownTable)
                        case None => Ok(schema)
                    })
                    |> Result.map(next -> (next, None))
            case "DROP" :: "CONSTRAINT" :: _ =>
                let dropped = List.drop(2, normalized) |> List.dropWhile(word -> List.memberOf(String.toUpperCase(word), List#{"IF", "EXISTS"}));
                Schema.dropConstraint({ table = name, constraint = nth(0, dropped) |> unquote }, schema)
                    |> Option.map(next -> (next, None))
                    |> Option.toOk(unknownTable)
            case "RENAME" :: "CONSTRAINT" :: _ :: "TO" :: _ =>
                Schema.renameConstraint({ table = name, oldName = unquote(nth(2, normalized)), newName = unquote(nth(4, normalized)) }, schema)
                    |> Option.map(next -> (next, None))
                    |> Option.toOk(unknownTable)
            case "ADD" :: _ => addColumn(name, List.drop(1, normalized), statement, schema)
            case "DROP" :: _ => dropColumn(name, nth(1, normalized), statement, schema)
            case "ALTER" :: _ :: "SET" :: "NOT" :: "NULL" :: _ => setNullable({ table = name, column = unquote(nth(1, normalized)) }, false, statement, schema)
            case "ALTER" :: _ :: "DROP" :: "NOT" :: "NULL" :: _ => setNullable({ table = name, column = unquote(nth(1, normalized)) }, true, statement, schema)
            case "ALTER" :: _ :: "TYPE" :: _ => setType({ table = name, column = unquote(nth(1, normalized)) }, List.drop(3, normalized), statement, schema)
            case "RENAME" :: _ :: "TO" :: _ => renameColumn({ table = name, column = unquote(nth(1, normalized)) }, unquote(nth(3, normalized)), statement, schema)
            case _ => Ok((schema, Some("unreadable DDL: ${List.take(3, "ALTER" :: "TABLE" :: action) |> List.join(" ")} ...")))
        }

    ///
    /// 省略可能な語（COLUMN / IF NOT EXISTS）を最初の動詞の直後から取り除く。
    ///
    def dropOptionalWords(optional: List[String], action: List[String]): List[String] =
        match action {
            case verb :: rest => verb :: List.dropWhile(word -> List.memberOf(String.toUpperCase(word), optional), rest)
            case Nil => Nil
        }

    ///
    /// `ADD CONSTRAINT` / `ADD PRIMARY KEY` / `ADD FOREIGN KEY` / `ADD UNIQUE` / `ADD CHECK` / `ADD EXCLUDE`。
    ///
    def isConstraintStart(upper: String): Bool =
        List.memberOf(upper, List#{"CONSTRAINT", "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "EXCLUDE"})

    ///
    /// ALTER の対象。テーブル名と列名は両方 String なので、並べずに名前で持つ。
    ///
    type alias ColumnRef = { table = String, column = String }

    def setNullable(target: ColumnRef, nullable: Bool, statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        updateColumn(target, column -> { name = column#name, columnType = column#columnType, nullable = nullable }, statement, schema)

    def setType(target: ColumnRef, typeWords: List[String], statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        let typeName = List.takeWhile(word -> String.toUpperCase(word) != "USING", typeWords) |> List.join(" ") |> String.toLowerCase |> stripLength;
        updateColumn(target, column -> { name = column#name, columnType = SqlType.fromPgName(typeName), nullable = column#nullable }, statement, schema)

    def renameColumn(target: ColumnRef, newName: String, statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        updateColumn(target, column -> { name = newName, columnType = column#columnType, nullable = column#nullable }, statement, schema)

    ///
    /// 1 列を差し替える。テーブルか列が無ければエラー。
    ///
    def updateColumn(target: ColumnRef, change: Column -> Column, statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        forM (
            found <- Schema.findTable(target#table, schema) |> Option.toOk(DdlError.UnknownTable(statement, target#table));
            _ <- Schema.findColumn(target#column, found) |> Option.toOk(DdlError.UnknownColumn(statement, target#column))
        ) yield {
            let columns = List.map(column -> if (column#name == target#column) change(column) else column, found#columns);
            (Schema.addTable({ name = found#name, columns = columns, constraints = found#constraints }, schema), None)
        }

    def addColumn(table: String, definition: List[String], statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        let unknownTable = DdlError.UnknownTable(statement, table);
        forM (
            parsed <- parseColumnDefinition(List.join(" ", definition), statement);
            withColumn <- Schema.addColumn(table, fst(parsed), schema) |> Option.toOk(unknownTable);
            next <- Result.foldLeftM((acc, constraint) -> Schema.addConstraint(table, constraint, acc) |> Option.toOk(unknownTable), withColumn, snd(parsed))
        ) yield (next, None)

    def dropColumn(table: String, rawColumn: String, statement: String, schema: Schema): Result[DdlError, (Schema, Option[String])] =
        let column = unquote(rawColumn);
        forM (
            _ <- Schema.findTable(table, schema) |> Option.toOk(DdlError.UnknownTable(statement, table));
            next <- Schema.dropColumn({ table = table, column = column }, schema) |> Option.toOk(DdlError.UnknownColumn(statement, column))
        ) yield (next, None)

    ///
    /// `name type [制約...]`。型は制約の語が出るまでの語を繋ぐ（`double precision` や `character varying(255)`）。
    /// 型が知らない物でも列は登録し、型だけ None にする。
    ///
    def parseColumn(definition: String): Option[Column] =
        match tokens(definition) {
            case rawName :: rest =>
                let typeWords = List.takeWhile(word -> not isConstraintWord(String.toUpperCase(word)), rest);
                let constraints = List.map(String.toUpperCase, rest);
                let typeName = List.join(" ", typeWords) |> String.toLowerCase |> stripLength;
                if (List.isEmpty(typeWords))
                    None
                else
                    Some({
                        name = unquote(rawName),
                        columnType = SqlType.fromPgName(typeName),
                        nullable = not (hasPair("NOT", "NULL", constraints) or hasPair("PRIMARY", "KEY", constraints))
                    })
            case Nil => None
        }

    ///
    /// `numeric(10, 2)` → `numeric`、`character varying(255)` → `character varying`。配列の `[]` は残す。
    ///
    def stripLength(typeName: String): String =
        match String.indexOf(substr = "(", typeName) {
            case Some(open) =>
                let close = String.indexOf(substr = ")", typeName) |> Option.getWithDefault(String.length(typeName) - 1);
                (String.slice(start = 0, end = open, typeName) + String.slice(start = close + 1, end = String.length(typeName), typeName))
                    |> String.trim
                    |> String.replace(src = " []", dst = "[]")
            case None => typeName
        }

    def hasPair(first: String, second: String, words: List[String]): Bool =
        List.zip(words, List.drop(1, words)) |> List.exists(pair -> pair == (first, second))

    ///
    /// 列定義の中で型の後ろに来る語。
    ///
    def isConstraintWord(upper: String): Bool =
        List.memberOf(upper, List#{"NOT", "NULL", "DEFAULT", "PRIMARY", "REFERENCES", "UNIQUE", "CHECK", "GENERATED", "COLLATE", "CONSTRAINT"})

    ///
    /// テーブル制約（列ではない定義）か。
    ///
    def isConstraint(definition: String): Bool =
        match tokens(definition) {
            case word :: _ => isConstraintStart(String.toUpperCase(word))
            case Nil => true
        }

    // ---- 字句 ----

    ///
    /// `;` で文に切る。`--` 行コメントは落とす。単一引用符の中の `;` は切らない。
    ///
    pub def splitStatements(sql: String): List[String] =
        String.splitOn(substr = "\n", sql)
            |> List.map(line -> match String.indexOf(substr = "--", line) { case Some(i) => String.takeLeft(i, line) case None => line })
            |> List.join("\n")
            |> splitTopLevel(';')
            |> List.map(String.trim)
            |> List.filter(statement -> not String.isEmpty(statement))

    ///
    /// 括弧の外・引用符の外にある区切り文字で切る。
    ///
    def splitTopLevel(separator: Char, text: String): List[String] =
        let (parts, current, _, _) = String.toList(text)
            |> List.foldLeft((state, ch) -> {
                let (done, buffer, depth, inQuote) = state;
                if (ch == '\'') (done, ch :: buffer, depth, not inQuote)
                else if (inQuote) (done, ch :: buffer, depth, true)
                else if (ch == '(') (done, ch :: buffer, depth + 1, false)
                else if (ch == ')') (done, ch :: buffer, depth - 1, false)
                else if (ch == separator and depth == 0) (charsToString(List.reverse(buffer)) :: done, Nil, depth, false)
                else (done, ch :: buffer, depth, false)
            }, (Nil, Nil, 0, false));
        List.reverse(charsToString(List.reverse(current)) :: parts)

    ///
    /// 空白で語に切る。`(` `)` `,` は前後の語から切り離す。
    ///
    def tokens(text: String): List[String] =
        text
            |> String.replace(src = "(", dst = " ( ")
            |> String.replace(src = ")", dst = " ) ")
            |> String.replace(src = ",", dst = " , ")
            |> String.splitOn(substr = " ")
            |> List.flatMap(word -> String.splitOn(substr = "\n", word))
            |> List.flatMap(word -> String.splitOn(substr = "\t", word))
            |> List.filter(word -> not String.isEmpty(word))

    ///
    /// 語の n 番目。無ければ空文字。
    ///
    def nth(n: Int32, words: List[String]): String =
        List.drop(n, words) |> List.head |> Option.getWithDefault("")

    ///
    /// `"Name"` → `Name`、`Name` → `name`（PG は引用符の無い識別子を小文字に畳む。DB が返す制約名やテーブル名と一致させる）。
    /// `public.users` → `users`。
    ///
    def unquote(word: String): String =
        let folded = if (String.contains(substr = "\"", word)) String.replace(src = "\"", dst = "", word) else String.toLowerCase(word);
        folded
            |> String.splitOn(substr = ".")
            |> List.last
            |> Option.getWithDefault(folded)

    def charsToString(chars: List[Char]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(ch -> StringBuilder.append(ch, sb), chars);
            StringBuilder.toString(sb)
        }

}
