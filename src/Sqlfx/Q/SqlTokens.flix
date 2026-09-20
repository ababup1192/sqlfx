///
/// SQL 本文を語に切る字句解析。スキーマ解決（QResolve）が FROM と SELECT リストを見るために使う。
/// 文字列リテラルは 1 語、`::` は 1 語、`( ) , . *` は単独の語、`$1` は 1 語。
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
            case '\'' :: rest =>
                let (literal, afterLiteral) = takeLiteral(rest, Nil);
                loop(afterLiteral, ("'" + charsToString(literal) + "'") :: acc)
            case '"' :: rest =>
                let quoted = List.takeWhile(c -> c != '"', rest);
                loop(List.drop(List.length(quoted) + 1, rest), charsToString(quoted) :: acc)
            case ':' :: ':' :: rest => loop(rest, "::" :: acc)
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
    /// SQL から NOT NULL の marker `!` を落とす。文字列リテラルの中は触らない。
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
            case '!' :: rest if not inQuote and isNotNullMark(previous = previous, rest) => dropLoop(rest, Some('!'), inQuote, acc)
            case ch :: rest => dropLoop(rest, Some(ch), inQuote, ch :: acc)
        }

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
