///
/// 語の並び（`SqlTokens.tokenize` の結果）を「CTE の並び + 本文」に切る。QResolve と QScope が同じ切り方を使う。
///
pub mod Sqlfx.Q.QCte {

    ///
    /// 文の一部。`start` / `end` は語の並び全体の中の位置（`end` は含まない）。
    ///
    /// WhyNot: 名前を `Unit` にしない（Flix の `Unit` 型とぶつかる）。
    ///
    pub type alias Part = { words = List[String], start = Int32, end = Int32 }

    ///
    /// CTE 1 つ。`name` は小文字（PG は引用符の無い識別子を小文字に畳む）。`columns` は `name(a, b)` の並び。
    ///
    pub type alias Cte = { name = String, columns = Option[List[String]], body = Part }

    ///
    /// 切った文。WITH が無ければ `ctes` は Nil で、`main` が全部。
    ///
    pub type alias Statement = { ctes = List[Cte], main = Part }

    pub enum CteError with Eq, ToString {
        /// (CTE の名前) WITH RECURSIVE
        case RecursiveCte(String)
        /// CTE の本文か副問い合わせの中の WITH
        case NestedWith
        /// (期待した物) 形が崩れている
        case Unexpected(String)
    }

    ///
    /// 切る。先頭が CTE の形の WITH でなければ全部を本文にする。どちらでも、CTE の本文と本文の中の CTE の形の WITH は NestedWith。
    ///
    pub def split(words: List[String]): Result[CteError, Statement] =
        let all = List.toVector(words);
        let total = Vector.length(all);
        let parsed = if (startsCte(0, all)) {
            if (upper(0, all) == "WITH" and upper(1, all) == "RECURSIVE") Err(CteError.RecursiveCte(String.toLowerCase(at(2, all))))
            else readCtes(1, all, Nil)
        } else Ok((Nil, 0));
        parsed |> Result.flatMap(match (ctes, mainStart) -> {
            let main = partOf(mainStart, total, all);
            let parts = main :: List.map(cte -> cte#body, ctes);
            if (List.exists(part -> hasNestedWith(part, all), parts)) Err(CteError.NestedWith)
            else Ok({ ctes = ctes, main = main })
        })

    ///
    /// i から CTE を 1 つずつ読む。戻りは (CTE の並び, 本文の始まり)。
    ///
    def readCtes(i: Int32, all: Vector[String], acc: List[Cte]): Result[CteError, (List[Cte], Int32)] =
        let name = String.toLowerCase(at(i, all));
        let (columns, afterColumns) = if (at(i + 1, all) == "(") readColumns(i + 2, all, Nil) else (None, i + 1);
        if (upper(afterColumns, all) != "AS") Err(CteError.Unexpected("AS after CTE ${name}"))
        else {
            let bodyOpen = skipMaterialized(afterColumns + 1, all);
            if (at(bodyOpen, all) != "(") Err(CteError.Unexpected("'(' opening CTE ${name}"))
            else match closingParen(bodyOpen, all) {
                case None => Err(CteError.Unexpected("')' closing CTE ${name}"))
                case Some(close) =>
                    let cte = { name = name, columns = columns, body = partOf(bodyOpen + 1, close, all) };
                    if (at(close + 1, all) == ",") readCtes(close + 2, all, cte :: acc)
                    else Ok((List.reverse(cte :: acc), close + 1))
            }
        }

    ///
    /// `(a, b)` のカラムの並びを `)` まで読む。戻りは (並び, `)` の後ろ)。
    ///
    def readColumns(i: Int32, all: Vector[String], acc: List[String]): (Option[List[String]], Int32) =
        let word = at(i, all);
        if (word == ")" or word == "") (Some(List.reverse(acc)), i + 1)
        else if (word == ",") readColumns(i + 1, all, acc)
        else readColumns(i + 1, all, String.toLowerCase(word) :: acc)

    ///
    /// `[NOT] MATERIALIZED` を読み飛ばす。
    ///
    def skipMaterialized(i: Int32, all: Vector[String]): Int32 =
        if (upper(i, all) == "MATERIALIZED") i + 1
        else if (upper(i, all) == "NOT" and upper(i + 1, all) == "MATERIALIZED") i + 2
        else i

    ///
    /// `(` の位置から、対応する `)` の位置。閉じが無ければ None。
    ///
    def closingParen(open: Int32, all: Vector[String]): Option[Int32] =
        def go(i: Int32, depth: Int32): Option[Int32] =
            if (i >= Vector.length(all)) None
            else {
                let word = at(i, all);
                let next = if (word == "(") depth + 1 else if (word == ")") depth - 1 else depth;
                if (next == 0) Some(i) else go(i + 1, next)
            };
        go(open, 0)

    ///
    /// i が CTE の始まりの WITH か: `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (`。
    ///
    def startsCte(i: Int32, all: Vector[String]): Bool =
        if (upper(i, all) != "WITH") false
        else {
            let nameAt = if (upper(i + 1, all) == "RECURSIVE") i + 2 else i + 1;
            let afterName = if (at(nameAt + 1, all) == "(") closingParen(nameAt + 1, all) |> Option.map(close -> close + 1) |> Option.getWithDefault(-1) else nameAt + 1;
            isIdentifier(at(nameAt, all)) and afterName > 0 and upper(afterName, all) == "AS" and at(skipMaterialized(afterName + 1, all), all) == "("
        }

    ///
    /// 文の一部の中に、CTE の形の WITH があるか。
    ///
    def hasNestedWith(part: Part, all: Vector[String]): Bool =
        List.range(part#start, part#end) |> List.exists(i -> startsCte(i, all))

    def partOf(start: Int32, end: Int32, all: Vector[String]): Part =
        { words = Vector.slice(start = start, end = end, all) |> Vector.toList, start = start, end = end }

    def isIdentifier(word: String): Bool =
        not String.isEmpty(word) and (Char.isLetter(String.charAt(0, word)) or String.charAt(0, word) == '_')

    def at(i: Int32, all: Vector[String]): String =
        Vector.nth(i, all) |> Option.getWithDefault("")

    def upper(i: Int32, all: Vector[String]): String =
        String.toUpperCase(at(i, all))

}
