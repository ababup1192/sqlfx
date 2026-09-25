///
/// SQL 本文を語に切る字句解析。スキーマ解決（QResolve）が FROM と SELECT リストを見るために使う。
/// 文字列リテラルは 1 語、`::` は 1 語、`( ) , . *` は単独の語、`$1` は 1 語。
/// `--` と `/* */`（PG と同じく入れ子を数える）は語にしない。dollar quote（`$$…$$` / `$tag$…$tag$`）は 1 語。
/// 語に直に続く NOT NULL の marker `!`（`bigint!`）は語の一部（`isNotNullMark`）。
///
pub mod Sqlfx.Q.SqlTokens {

    ///
    /// 語に切る。
    ///
    pub def tokenize(sql: String): List[String] =
        loop(String.toList(sql), Nil)

    def loop(chars: List[Char], acc: List[String]): List[String] =
        match chars {
            case Nil => List.reverse(acc)
            case ch :: rest if Char.isWhitespace(ch) => loop(rest, acc)
            case '-' :: '-' :: rest => loop(List.dropWhile(c -> c != '\n', rest), acc)
            case '/' :: '*' :: rest => loop(List.drop(blockCommentLength(rest), rest), acc)
            case '\'' :: rest =>
                let (literal, afterLiteral) = takeLiteral(rest, Nil);
                loop(afterLiteral, ("'" + charsToString(literal) + "'") :: acc)
            case '"' :: rest =>
                let quoted = List.takeWhile(c -> c != '"', rest);
                loop(List.drop(List.length(quoted) + 1, rest), charsToString(quoted) :: acc)
            case ':' :: ':' :: rest => loop(rest, "::" :: acc)
            case '$' :: _ if Option.nonEmpty(dollarQuoteLength(chars)) =>
                let length = dollarQuoteLength(chars) |> Option.getWithDefault(1);
                loop(List.drop(length, chars), charsToString(List.take(length, chars)) :: acc)
            case '$' :: rest =>
                let digits = List.takeWhile(Char.isDigit, rest);
                loop(List.drop(List.length(digits), rest), ("$" + charsToString(digits)) :: acc)
            case ch :: _ if isWordChar(ch) =>
                let word = List.takeWhile(isWordChar, chars);
                let afterWord = List.drop(List.length(word), chars);
                match afterWord {
                    case '!' :: following if isNotNullMark(previous = Some(List.last(word) |> Option.getWithDefault(' ')), following) =>
                        loop(following, (charsToString(word) + "!") :: acc)
                    case _ => loop(afterWord, charsToString(word) :: acc)
                }
            case ch :: rest => loop(rest, Char.toString(ch) :: acc)
        }

    def isWordChar(ch: Char): Bool = Char.isLetterOrDigit(ch) or ch == '_'

    ///
    /// `/*` の後ろから、対応する `*/` の後ろまでの文字数。入れ子の `/* */` を数える。閉じが無ければ最後まで。
    ///
    pub def blockCommentLength(chars: List[Char]): Int32 =
        blockCommentLoop(chars, 1, 0)

    def blockCommentLoop(chars: List[Char], depth: Int32, consumed: Int32): Int32 =
        match chars {
            case Nil                => consumed
            case '*' :: '/' :: rest => if (depth == 1) consumed + 2 else blockCommentLoop(rest, depth - 1, consumed + 2)
            case '/' :: '*' :: rest => blockCommentLoop(rest, depth + 1, consumed + 2)
            case _ :: rest          => blockCommentLoop(rest, depth, consumed + 1)
        }

    ///
    /// `$` から始まる文字の並びが dollar quote なら、閉じの `$tag$` までを含めた文字数。
    /// tag は空か、英字か `_` で始まる語の文字。`$1` のような `$` + 数字は dollar quote でない。閉じが無ければ最後まで。
    ///
    pub def dollarQuoteLength(chars: List[Char]): Option[Int32] =
        match chars {
            case '$' :: rest => dollarTag(rest) |> Option.map(tag -> {
                let opening = List.length(tag) + 2;
                let delimiter = '$' :: tag ::: '$' :: Nil;
                opening + closingLength(List.drop(opening, chars), delimiter, 0)
            })
            case _ => None
        }

    ///
    /// 開きの `$` の後ろが `tag$` か。tag の文字（空もある）。
    ///
    def dollarTag(chars: List[Char]): Option[List[Char]] =
        match chars {
            case '$' :: _ => Some(Nil)
            case ch :: _ if Char.isLetter(ch) or ch == '_' =>
                let tag = List.takeWhile(isWordChar, chars);
                match List.drop(List.length(tag), chars) {
                    case '$' :: _ => Some(tag)
                    case _        => None
                }
            case _ => None
        }

    ///
    /// 中身の先頭から、閉じの delimiter の後ろまでの文字数。
    ///
    def closingLength(chars: List[Char], delimiter: List[Char], consumed: Int32): Int32 =
        if (List.isEmpty(chars)) consumed
        else if (List.take(List.length(delimiter), chars) == delimiter) consumed + List.length(delimiter)
        else closingLength(List.drop(1, chars), delimiter, consumed + 1)

    ///
    /// `!` が NOT NULL の marker か。直前が語の文字で、直後が `=` `~` `!` でない物（`!=` `!~` `!!` は演算子）。
    ///
    /// WhyNot: 空白を挟んだ `bigint !` を marker にしないのは、字句を語に付けた形に固定して、
    /// SQL から落とす側（`dropNotNullMarks`）と QResolve が見る側の判定を 1 つにするため。
    ///
    pub def isNotNullMark(previous: {previous = Option[Char]}, following: List[Char]): Bool =
        let afterWord = match previous#previous {
            case Some(ch) => isWordChar(ch)
            case None => false
        };
        let startsOperator = match following {
            case '=' :: _ => true
            case '~' :: _ => true
            case '!' :: _ => true
            case _ => false
        };
        afterWord and not startsOperator

    ///
    /// SQL から NOT NULL の marker `!` を落とす。文字列リテラル・dollar quote・`--` と `/* */` のコメントの中は触らない。
    ///
    pub def dropNotNullMarks(sql: String): String =
        dropLoop(String.toList(sql), None, false, Nil) |> List.reverse |> charsToString

    ///
    /// (未読, 直前の文字, 引用符の中か, 出力の逆順)。
    ///
    def dropLoop(chars: List[Char], previous: Option[Char], inQuote: Bool, acc: List[Char]): List[Char] =
        match chars {
            case Nil => acc
            case '\'' :: rest => dropLoop(rest, Some('\''), not inQuote, '\'' :: acc)
            case '/' :: '*' :: rest if not inQuote => copyVerbatim(2 + blockCommentLength(rest), chars, acc)
            case '-' :: '-' :: rest if not inQuote => copyVerbatim(2 + List.length(List.takeWhile(c -> c != '\n', rest)), chars, acc)
            case '$' :: _ if not inQuote and Option.nonEmpty(dollarQuoteLength(chars)) =>
                copyVerbatim(dollarQuoteLength(chars) |> Option.getWithDefault(1), chars, acc)
            case '!' :: rest if not inQuote and isNotNullMark(previous = previous, rest) => dropLoop(rest, Some('!'), inQuote, acc)
            case ch :: rest => dropLoop(rest, Some(ch), inQuote, ch :: acc)
        }

    ///
    /// 先頭の length 文字をそのまま写し、続きを dropLoop に戻す。
    ///
    def copyVerbatim(length: Int32, chars: List[Char], acc: List[Char]): List[Char] =
        let copied = List.take(length, chars);
        dropLoop(List.drop(length, chars), List.last(copied), false, List.reverse(copied) ::: acc)

    ///
    /// 開き `'` の後ろから閉じ `'` まで読む。`''` は 1 つの `'` として続ける。戻りは (中身の逆順を正順に, 閉じの後ろ)。
    ///
    def takeLiteral(chars: List[Char], acc: List[Char]): (List[Char], List[Char]) =
        match chars {
            case '\'' :: '\'' :: rest => takeLiteral(rest, '\'' :: acc)
            case '\'' :: rest => (List.reverse(acc), rest)
            case ch :: rest => takeLiteral(rest, ch :: acc)
            case Nil => (List.reverse(acc), Nil)
        }

    ///
    /// 括弧の深さ 0 にある区切り語で切る。
    ///
    pub def splitTopLevel(separator: String, words: List[String]): List[List[String]] =
        let (groups, current, _) = List.foldLeft((state, word) -> {
            let (done, buffer, depth) = state;
            if (word == "(") (done, word :: buffer, depth + 1)
            else if (word == ")") (done, word :: buffer, depth - 1)
            else if (word == separator and depth == 0) (List.reverse(buffer) :: done, Nil, depth)
            else (done, word :: buffer, depth)
        }, (Nil, Nil, 0), words);
        List.reverse(List.reverse(current) :: groups)

    ///
    /// 括弧の深さ 0 で最初に `keyword`（大文字小文字は問わない）が出る位置。
    ///
    pub def indexOfTopLevel(keyword: String, words: List[String]): Option[Int32] =
        let (found, _, _) = List.foldLeft((state, word) -> {
            let (result, depth, index) = state;
            let next = if (word == "(") depth + 1 else if (word == ")") depth - 1 else depth;
            match result {
                case Some(_) => (result, next, index + 1)
                case None if depth == 0 and String.toUpperCase(word) == keyword => (Some(index), next, index + 1)
                case None => (None, next, index + 1)
            }
        }, (None, 0, 0), words);
        found

    def charsToString(chars: List[Char]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(ch -> StringBuilder.append(ch, sb), chars);
            StringBuilder.toString(sb)
        }

}
