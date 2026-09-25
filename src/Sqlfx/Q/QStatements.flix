///
/// query ごとの文の一覧（`gen --statements` が書く JSON）。利用側の check（「`entry_contents.data` を書く query は
/// `entries.updated_at` も書く」のような物）が、SQL のパーサをもう 1 つ持たずに済むように、生成器が読んだ結果を書き出す。
///
pub mod Sqlfx.Q.QStatements {

    use Sqlfx.Q.QCte
    use Sqlfx.Q.QRender
    use Sqlfx.Q.QueryDef
    use Sqlfx.Q.SqlTokens

    use Sqlfx.Q.QueryDef.Query

    ///
    /// 文 1 つ。
    ///
    /// - `name`: CTE の名前か `main`（本文）
    /// - `kind`: `select` / `insert` / `update` / `delete`（それ以外は先頭の語の小文字）
    /// - `target`: 書き込み先の表。SELECT は None
    /// - `columns`: INSERT のカラムの並びか、UPDATE の SET の左辺。Changes の slot の SET は `*`（何を書くかは呼ぶ側が決める）
    /// - `conflictSet`: `ON CONFLICT DO UPDATE SET` の左辺
    ///
    pub type alias Statement = { name = String, kind = String, target = Option[String], columns = List[String], conflictSet = List[String] }

    ///
    /// query の文。WITH を含めば CTE を前から、最後に本文（`main`）。WITH が無ければ本文 1 つ。
    ///
    pub def of(queryDef: Query): List[Statement] =
        let (sql, _) = QRender.toSql(queryDef);
        let words = SqlTokens.tokenize(sql);
        let parts = match QCte.split(words) {
            case Ok(statement) => List.map(cte -> (cte#name, cte#body#words), statement#ctes) ::: ("main", statement#main#words) :: Nil
            case Err(_)        => ("main", words) :: Nil
        };
        List.map(match (name, partWords) -> statementOf(name, List.toVector(partWords)), parts)

    def statementOf(name: String, words: Vector[String]): Statement =
        let first = upperAt(0, words);
        let kind = match first {
            case "SELECT" => "select"
            case "INSERT" => "insert"
            case "UPDATE" => "update"
            case "DELETE" => "delete"
            case other    => String.toLowerCase(other)
        };
        let targetAt = match first {
            case "INSERT" => indexOf("INTO", 0, words) |> Option.map(at -> at + 1)
            case "UPDATE" => Some(1)
            case "DELETE" => indexOf("FROM", 0, words) |> Option.map(at -> at + 1)
            case _        => None
        };
        let target = targetAt |> Option.map(at -> tableAt(at, words));
        let columns = match (first, targetAt) {
            case ("INSERT", Some(at)) => insertColumns(afterTable(at, words), words)
            case ("UPDATE", _)        => topLevelIndexOf("SET", words) |> Option.map(at -> setColumns(at + 1, words)) |> Option.getWithDefault(Nil)
            case _                    => Nil
        };
        let conflictSet = if (first == "INSERT") conflictSetColumns(words) else Nil;
        { name = name, kind = kind, target = target, columns = columns, conflictSet = conflictSet }

    ///
    /// 位置 at の表の名前。`ONLY t`、`public.t` は t。
    ///
    def tableAt(at: Int32, words: Vector[String]): String =
        let start = if (upperAt(at, words) == "ONLY") at + 1 else at;
        if (wordAt(start + 1, words) == ".") wordAt(start + 2, words) else wordAt(start, words)

    ///
    /// 位置 at の表の名前の後ろ。
    ///
    def afterTable(at: Int32, words: Vector[String]): Int32 =
        let start = if (upperAt(at, words) == "ONLY") at + 1 else at;
        if (wordAt(start + 1, words) == ".") start + 3 else start + 1

    ///
    /// `INSERT INTO t (a, b)` のカラムの並び。並びが無ければ空。
    ///
    def insertColumns(at: Int32, words: Vector[String]): List[String] =
        if (wordAt(at, words) != "(") Nil
        else List.range(at + 1, Vector.length(words))
            |> List.map(i -> wordAt(i, words))
            |> List.takeWhile(word -> word != ")")
            |> List.filter(word -> word != ",")
            |> List.map(String.toLowerCase)

    ///
    /// SET の後ろから、深さ 0 の WHERE / FROM / RETURNING（ON CONFLICT の中なら WHERE / RETURNING）までの左辺。
    /// 空の項目（Changes の slot の置き文字）は `*`、`(a, b) = …` は a と b。
    ///
    def setColumns(at: Int32, words: Vector[String]): List[String] =
        let clause = topLevelUntil(at, List#{"WHERE", "FROM", "RETURNING"}, words);
        SqlTokens.splitTopLevel(",", clause) |> List.flatMap(item -> match item {
            case Nil         => "*" :: Nil
            case "(" :: rest => List.takeWhile(word -> word != ")", rest) |> List.filter(word -> word != ",") |> List.map(String.toLowerCase)
            case column :: _ => String.toLowerCase(column) :: Nil
        })

    ///
    /// `ON CONFLICT … DO UPDATE SET` の左辺。
    ///
    def conflictSetColumns(words: Vector[String]): List[String] =
        List.range(0, Vector.length(words))
            |> List.find(i -> upperAt(i, words) == "DO" and upperAt(i + 1, words) == "UPDATE" and upperAt(i + 2, words) == "SET")
            |> Option.map(at -> setColumns(at + 3, words))
            |> Option.getWithDefault(Nil)

    ///
    /// at から、深さ 0 で stops のどれかが出る手前までの語。
    ///
    def topLevelUntil(at: Int32, stops: List[String], words: Vector[String]): List[String] =
        def go(i: Int32, depth: Int32, acc: List[String]): List[String] =
            if (i >= Vector.length(words)) List.reverse(acc)
            else {
                let word = wordAt(i, words);
                if (depth == 0 and List.memberOf(String.toUpperCase(word), stops)) List.reverse(acc)
                else go(i + 1, if (word == "(") depth + 1 else if (word == ")") depth - 1 else depth, word :: acc)
            };
        go(at, 0, Nil)

    def topLevelIndexOf(keyword: String, words: Vector[String]): Option[Int32] =
        SqlTokens.indexOfTopLevel(keyword, Vector.toList(words))

    def indexOf(keyword: String, start: Int32, words: Vector[String]): Option[Int32] =
        List.range(start, Vector.length(words)) |> List.find(i -> upperAt(i, words) == keyword)

    def wordAt(i: Int32, words: Vector[String]): String = Vector.nth(i, words) |> Option.getWithDefault("")

    def upperAt(i: Int32, words: Vector[String]): String = String.toUpperCase(wordAt(i, words))

    ///
    /// JSON にする。1 query 1 line の配列。`target` は SELECT 以外、`columns` は INSERT / UPDATE、`conflictSet` は在る時だけ。
    ///
    pub def toJson(queries: List[(String, Query)]): String =
        match queries {
            case Nil => "[]\n"
            case _   =>
                let lines = List.map(match (fileName, queryDef) ->
                    "  {\"file\": ${quoted(fileName)}, \"query\": ${quoted(queryDef#name)}, \"statements\": [${List.join(", ", List.map(statementJson, of(queryDef)))}]}", queries);
                "[\n" + List.join(",\n", lines) + "\n]\n"
        }

    def statementJson(statement: Statement): String =
        let fields =
            ("\"name\": ${quoted(statement#name)}" :: "\"kind\": ${quoted(statement#kind)}" :: Nil)
            ::: (statement#target |> Option.map(target -> "\"target\": ${quoted(target)}") |> Option.toList)
            ::: (if (statement#kind == "insert" or statement#kind == "update") "\"columns\": ${quotedList(statement#columns)}" :: Nil else Nil)
            ::: (if (List.isEmpty(statement#conflictSet)) Nil else "\"conflictSet\": ${quotedList(statement#conflictSet)}" :: Nil);
        "{${List.join(", ", fields)}}"

    def quotedList(items: List[String]): String = "[${List.join(", ", List.map(quoted, items))}]"

    def quoted(text: String): String =
        "\"" + (text |> String.replace(src = "\\", dst = "\\\\") |> String.replace(src = "\"", dst = "\\\"")) + "\""

}
