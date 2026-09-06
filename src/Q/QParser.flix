///
/// `.q` ファイルのパーサ（design.md §3）。外側の `query ...` は文法として読み、`{ }` の中は素の SQL として
/// `:name` と `{slot}` だけを切り出す。エラーは最初の 1 つで止める。
///
/// WhyNot: 行番号ではなく文字位置で報告するのは、LSP が欲しがるのが offset だから。行番号への変換は表示側でやる。
///
mod QParser {

    use QueryDef.Shape
    use SqlType.SqlType
    use QueryDef.SlotKind
    use QueryDef.Segment
    use QueryDef.Param
    use QueryDef.Slot
    use QueryDef.Query

    ///
    /// パースの失敗。位置は先頭からの文字数（0 始まり）。
    ///
    pub enum ParseError with Eq, Order, ToString {
        /// その位置に期待した物が無い（期待した物の説明）
        case Unexpected(Int32, String)
        /// 型名の綴りが未知（位置, 綴り）
        case UnknownType(Int32, String)
        /// `:name` が宣言に無い（クエリ名, 引数名）
        case UndeclaredParam(String, String)
        /// 宣言した引数を本文で使っていない（クエリ名, 引数名）
        case UnusedParam(String, String)
        /// `{name}` が with 節に無い（クエリ名, slot 名）
        case UndeclaredSlot(String, String)
        /// with 節の slot を本文で使っていない（クエリ名, slot 名）
        case UnusedSlot(String, String)
        /// `keyed` は many にしか付けられない（クエリ名）
        case KeyedRequiresMany(String)
        /// 同じ名前の query が 2 つ（クエリ名）
        case DuplicateQuery(String)
    }

    ///
    /// 読み位置。`rest` は未読の文字、`pos` はその先頭の位置。
    ///
    type alias Cursor = { rest = List[Char], pos = Int32 }

    ///
    /// ファイル全体を読む。
    ///
    pub def parseFile(source: String): Result[ParseError, List[Query]] =
        forM (
            queries <- parseQueries({ rest = String.toList(source), pos = 0 }, Nil);
            _ <- checkDuplicates(queries)
        ) yield queries

    ///
    /// `query` を無くなるまで読む。
    ///
    def parseQueries(cursor: Cursor, acc: List[Query]): Result[ParseError, List[Query]] =
        let cursorAtToken = skipTrivia(cursor);
        if (List.isEmpty(cursorAtToken#rest))
            Ok(List.reverse(acc))
        else
            forM (
                afterKeyword <- expectWord("query", cursorAtToken);
                (queryDef, next) <- parseQuery(afterKeyword);
                _ <- checkReferences(queryDef);
                rest <- parseQueries(next, queryDef :: acc)
            ) yield rest

    ///
    /// `名前(引数) -> 形 [keyed(col)] [with slot, ...] { 本文 }`。
    ///
    def parseQuery(cursor: Cursor): Result[ParseError, (Query, Cursor)] =
        forM (
            (name, afterName) <- expectIdent("query name", cursor);
            afterOpen <- expectChar('(', afterName);
            (params, afterParams) <- parseParams(afterOpen, Nil);
            afterArrow <- expectWord("->", afterParams);
            (shape, afterShape) <- parseShape(afterArrow);
            (keyed, afterKeyed) <- parseKeyed(afterShape);
            (slots, afterSlots) <- parseWith(afterKeyed);
            afterBrace <- expectChar('{', afterSlots);
            (body, afterBody) <- parseBody(afterBrace);
            _ <- if (Option.isEmpty(keyed) or shape == Shape.Many) Ok(()) else Err(ParseError.KeyedRequiresMany(name))
        ) yield ({ name = name, params = params, shape = shape, keyed = keyed, slots = slots, body = body }, afterBody)

    ///
    /// `name: Type, ...)`。閉じ括弧まで読む。
    ///
    def parseParams(cursor: Cursor, acc: List[Param]): Result[ParseError, (List[Param], Cursor)] =
        let cursorAtToken = skipTrivia(cursor);
        match cursorAtToken#rest {
            case ')' :: rest => Ok((List.reverse(acc), { rest = rest, pos = cursorAtToken#pos + 1 }))
            case _ =>
                forM (
                    (name, afterName) <- expectIdent("parameter name", cursorAtToken);
                    afterColon <- expectChar(':', afterName);
                    (paramType, afterType) <- parseParamType(afterColon);
                    afterSeparator <- skipOptionalChar(',', afterType);
                    result <- parseParams(afterSeparator, { name = name, paramType = paramType } :: acc)
                ) yield result
        }

    ///
    /// `Int64` や `List[Int64]`。綴りを丸ごと取って SqlType.fromFlixName に渡す。
    ///
    def parseParamType(cursor: Cursor): Result[ParseError, (SqlType, Cursor)] =
        let cursorAtToken = skipTrivia(cursor);
        let spelling = List.takeWhile(ch -> Char.isLetterOrDigit(ch) or ch == '[' or ch == ']', cursorAtToken#rest) |> charsToString;
        let next = advance(String.length(spelling), cursorAtToken);
        match SqlType.fromFlixName(spelling) {
            case Some(paramType) => Ok((paramType, next))
            case None => Err(ParseError.UnknownType(cursorAtToken#pos, spelling))
        }

    ///
    /// `one | many | exec`。
    ///
    def parseShape(cursor: Cursor): Result[ParseError, (Shape, Cursor)] =
        forM ((word, next) <- expectIdent("one / many / exec", cursor);
              shape <- match word {
                  case "one" => Ok(Shape.One)
                  case "many" => Ok(Shape.Many)
                  case "exec" => Ok(Shape.Exec)
                  case _ => Err(ParseError.Unexpected(skipTrivia(cursor)#pos, "one / many / exec"))
              }
        ) yield (shape, next)

    ///
    /// 省略可能な `keyed(col)`。
    ///
    def parseKeyed(cursor: Cursor): Result[ParseError, (Option[String], Cursor)] =
        if (startsWithWord("keyed", cursor))
            forM (
                afterKeyword <- expectWord("keyed", cursor);
                afterOpen <- expectChar('(', afterKeyword);
                (column, afterColumn) <- expectIdent("column name", afterOpen);
                afterClose <- expectChar(')', afterColumn)
            ) yield (Some(column), afterClose)
        else
            Ok((None, cursor))

    ///
    /// 省略可能な `with name: Pred[table], ...`。`{` の手前まで読む。
    ///
    def parseWith(cursor: Cursor): Result[ParseError, (List[Slot], Cursor)] =
        if (startsWithWord("with", cursor))
            forM (afterKeyword <- expectWord("with", cursor); result <- parseSlots(afterKeyword, Nil)) yield result
        else
            Ok((Nil, cursor))

    ///
    /// slot 宣言を `,` 区切りで読む。`{` が見えたら終わり。
    ///
    def parseSlots(cursor: Cursor, acc: List[Slot]): Result[ParseError, (List[Slot], Cursor)] =
        let cursorAtToken = skipTrivia(cursor);
        match cursorAtToken#rest {
            case '{' :: _ => Ok((List.reverse(acc), cursorAtToken))
            case _ =>
                forM (
                    (name, afterName) <- expectIdent("slot name", cursorAtToken);
                    afterColon <- expectChar(':', afterName);
                    (kindWord, afterKind) <- expectIdent("Pred / Order / Changes", afterColon);
                    kind <- match kindWord {
                        case "Pred" => Ok(SlotKind.Pred)
                        case "Order" => Ok(SlotKind.Order)
                        case "Changes" => Ok(SlotKind.Changes)
                        case _ => Err(ParseError.Unexpected(skipTrivia(afterColon)#pos, "Pred / Order / Changes"))
                    };
                    afterOpen <- expectChar('[', afterKind);
                    (table, afterTable) <- expectIdent("table name", afterOpen);
                    afterClose <- expectChar(']', afterTable);
                    afterSeparator <- skipOptionalChar(',', afterClose);
                    result <- parseSlots(afterSeparator, { name = name, kind = kind, table = table } :: acc)
                ) yield result
        }

    ///
    /// `{` の後から対応する `}` までを断片に切る。単一引用符の中は触らず、`::`（キャスト）は `:name` にしない。
    /// `--` から行末は SQL のコメントとして落とす（中の `'` や `:x` を見ないため）。
    /// `{name}` は slot 参照。前後の空白は落とす。
    ///
    def parseBody(cursor: Cursor): Result[ParseError, (List[Segment], Cursor)] =
        bodyLoop(cursor, Nil, Nil, false)

    ///
    /// 1 文字ずつ読む。`text` は読みかけの素の SQL（逆順）、`acc` は確定した断片（逆順）。
    ///
    def bodyLoop(cursor: Cursor, text: List[Char], acc: List[Segment], inQuote: Bool): Result[ParseError, (List[Segment], Cursor)] =
        match cursor#rest {
            case Nil => Err(ParseError.Unexpected(cursor#pos, "'}' closing the query body"))
            case '\'' :: rest => bodyLoop({ rest = rest, pos = cursor#pos + 1 }, '\'' :: text, acc, not inQuote)
            case ch :: rest if inQuote => bodyLoop({ rest = rest, pos = cursor#pos + 1 }, ch :: text, acc, true)
            case '}' :: rest => Ok((finishBody(text, acc), { rest = rest, pos = cursor#pos + 1 }))
            case '-' :: '-' :: rest =>
                let comment = List.takeWhile(ch -> ch != '\n', rest);
                bodyLoop(advance(2 + List.length(comment), cursor), text, acc, false)
            case ':' :: ':' :: rest => bodyLoop({ rest = rest, pos = cursor#pos + 2 }, ':' :: ':' :: text, acc, false)
            case ':' :: rest if startsWithIdent(rest) =>
                let (name, afterName) = takeIdent({ rest = rest, pos = cursor#pos + 1 });
                bodyLoop(afterName, Nil, Segment.ParamRef(name) :: flushText(text, acc), false)
            case '{' :: rest if startsWithIdent(rest) =>
                let (name, afterName) = takeIdent({ rest = rest, pos = cursor#pos + 1 });
                forM (afterClose <- expectChar('}', afterName);
                      result <- bodyLoop(afterClose, Nil, Segment.SlotRef(name) :: flushText(text, acc), false)
                ) yield result
            case '{' :: _ => Err(ParseError.Unexpected(cursor#pos, "slot name after '{'"))
            case ch :: rest => bodyLoop({ rest = rest, pos = cursor#pos + 1 }, ch :: text, acc, false)
        }

    ///
    /// 読みかけの素の SQL を断片にして積む。空なら何もしない。
    ///
    def flushText(text: List[Char], acc: List[Segment]): List[Segment] =
        if (List.isEmpty(text)) acc else Segment.Text(List.reverse(text) |> charsToString) :: acc

    ///
    /// 本文の終わり。最後の素の SQL を積んで正順に戻し、先頭と末尾の空白を落とす。
    ///
    def finishBody(text: List[Char], acc: List[Segment]): List[Segment] =
        flushText(text, acc) |> List.reverse |> trimEnds

    ///
    /// 先頭断片の左と末尾断片の右の空白を落とす。空になった断片は消す。
    ///
    def trimEnds(segments: List[Segment]): List[Segment] =
        let trimmedHead = match segments {
            case Segment.Text(text) :: rest => Segment.Text(String.trimLeft(text)) :: rest
            case other => other
        };
        let trimmedTail = match List.reverse(trimmedHead) {
            case Segment.Text(text) :: rest => List.reverse(Segment.Text(String.trimRight(text)) :: rest)
            case other => List.reverse(other)
        };
        List.filter(segment -> segment != Segment.Text(""), trimmedTail)

    // ---- 参照の検査 ----

    ///
    /// `:name` と `{slot}` が宣言と 1:1 で対応しているか。
    ///
    def checkReferences(queryDef: Query): Result[ParseError, Unit] =
        let usedParams = List.filterMap(segment -> match segment { case Segment.ParamRef(name) => Some(name) case _ => None }, queryDef#body);
        let usedSlots = List.filterMap(segment -> match segment { case Segment.SlotRef(name) => Some(name) case _ => None }, queryDef#body);
        let declaredParams = List.map(param -> param#name, queryDef#params);
        let declaredSlots = List.map(slot -> slot#name, queryDef#slots);
        forM (
            _ <- firstMissing(usedParams, declaredParams) |> Option.map(name -> ParseError.UndeclaredParam(queryDef#name, name)) |> toResult;
            _ <- firstMissing(declaredParams, usedParams) |> Option.map(name -> ParseError.UnusedParam(queryDef#name, name)) |> toResult;
            _ <- firstMissing(usedSlots, declaredSlots) |> Option.map(name -> ParseError.UndeclaredSlot(queryDef#name, name)) |> toResult;
            _ <- firstMissing(declaredSlots, usedSlots) |> Option.map(name -> ParseError.UnusedSlot(queryDef#name, name)) |> toResult
        ) yield ()

    ///
    /// `names` のうち `pool` に無い最初の物。
    ///
    def firstMissing(names: List[String], pool: List[String]): Option[String] =
        List.find(name -> not List.memberOf(name, pool), names)

    ///
    /// Some(error) なら Err、None なら Ok。
    ///
    def toResult(error: Option[ParseError]): Result[ParseError, Unit] =
        match error {
            case Some(e) => Err(e)
            case None => Ok(())
        }

    ///
    /// 同じ名前の query が 2 つ無いか。
    ///
    def checkDuplicates(queries: List[Query]): Result[ParseError, Unit] =
        let names = List.map(queryDef -> queryDef#name, queries);
        List.find(name -> List.count(other -> other == name, names) > 1, names)
            |> Option.map(name -> ParseError.DuplicateQuery(name))
            |> toResult

    // ---- 字句 ----

    ///
    /// 空白と `//` 行コメントを飛ばす。
    ///
    def skipTrivia(cursor: Cursor): Cursor =
        match cursor#rest {
            case '/' :: '/' :: rest =>
                let comment = List.takeWhile(ch -> ch != '\n', rest);
                skipTrivia(advance(2 + List.length(comment), cursor))
            case ch :: _ if Char.isWhitespace(ch) => skipTrivia(advance(1, cursor))
            case _ => cursor
        }

    ///
    /// n 文字進める。
    ///
    def advance(n: Int32, cursor: Cursor): Cursor =
        { rest = List.drop(n, cursor#rest), pos = cursor#pos + n }

    ///
    /// 空白を飛ばした先が `word` で始まるか。
    ///
    def startsWithWord(word: String, cursor: Cursor): Bool =
        List.isPrefixOf(String.toList(word), skipTrivia(cursor)#rest)

    ///
    /// 空白を飛ばして `word` を読む。無ければ Unexpected。
    ///
    def expectWord(word: String, cursor: Cursor): Result[ParseError, Cursor] =
        let cursorAtToken = skipTrivia(cursor);
        if (List.isPrefixOf(String.toList(word), cursorAtToken#rest))
            Ok(advance(String.length(word), cursorAtToken))
        else
            Err(ParseError.Unexpected(cursorAtToken#pos, "'${word}'"))

    ///
    /// 空白を飛ばして 1 文字を読む。
    ///
    def expectChar(expected: Char, cursor: Cursor): Result[ParseError, Cursor] =
        let cursorAtToken = skipTrivia(cursor);
        match cursorAtToken#rest {
            case ch :: _ if ch == expected => Ok(advance(1, cursorAtToken))
            case _ => Err(ParseError.Unexpected(cursorAtToken#pos, "'${expected}'"))
        }

    ///
    /// 空白を飛ばして、あれば 1 文字を読む。無くても進めない。
    ///
    def skipOptionalChar(expected: Char, cursor: Cursor): Result[ParseError, Cursor] =
        let cursorAtToken = skipTrivia(cursor);
        match cursorAtToken#rest {
            case ch :: _ if ch == expected => Ok(advance(1, cursorAtToken))
            case _ => Ok(cursorAtToken)
        }

    ///
    /// 空白を飛ばして識別子を読む。無ければ Unexpected（`what` は期待した物の説明）。
    ///
    def expectIdent(what: String, cursor: Cursor): Result[ParseError, (String, Cursor)] =
        let cursorAtToken = skipTrivia(cursor);
        if (startsWithIdent(cursorAtToken#rest))
            Ok(takeIdent(cursorAtToken))
        else
            Err(ParseError.Unexpected(cursorAtToken#pos, what))

    ///
    /// 識別子で始まるか（英字か `_`）。
    ///
    def startsWithIdent(chars: List[Char]): Bool =
        match chars {
            case ch :: _ => Char.isLetter(ch) or ch == '_'
            case Nil => false
        }

    ///
    /// 識別子（英数字と `_`）を読む。呼ぶ前に startsWithIdent で確かめること。
    ///
    def takeIdent(cursor: Cursor): (String, Cursor) =
        let ident = List.takeWhile(ch -> Char.isLetterOrDigit(ch) or ch == '_', cursor#rest) |> charsToString;
        (ident, advance(String.length(ident), cursor))

    ///
    /// 文字の列を String に戻す。
    ///
    def charsToString(chars: List[Char]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(ch -> StringBuilder.append(ch, sb), chars);
            StringBuilder.toString(sb)
        }

}
