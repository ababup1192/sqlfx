///
/// 日時の書式。中身はトークンの List で、`pattern` が限定した書式文字列から 1 回だけ変換する。
///
/// WhyNot: 書式文字列をそのまま Java に渡さないのは、`YYYY`（週年）や `hh`（12 時間）の取り違えが実行するまで分からないから。
/// `pattern` は意味が 1 つに決まる文字だけを受け、それ以外は bug! で止める。書式はリテラルなので、テストを 1 回通せば見つかる。
///
mod Format {

    pub enum Format with Eq, Order, ToString {
        /// 2026
        case Year
        /// 9
        case Month
        /// 09
        case Month2
        /// September
        case MonthName
        /// 6
        case Day
        /// 06
        case Day2
        /// Sunday
        case Weekday
        /// 01（24 時間）
        case Hour2
        case Minute2
        case Second2
        /// 456
        case Millis3
        /// JST
        case ZoneName
        /// +09:00
        case Offset
        /// そのまま出す文字
        case Text(String)
    }

    ///
    /// 書式文字列からトークンへ。受ける文字は次の通りで、`'...'` の中は素の文字、それ以外の記号もそのまま出す。
    ///
    /// | 文字 | 出力 |
    /// |---|---|
    /// | `yyyy` | 2026 |
    /// | `M` / `MM` / `MMMM` | 9 / 09 / September |
    /// | `d` / `dd` | 6 / 06 |
    /// | `EEEE` | Sunday |
    /// | `HH` / `mm` / `ss` / `SSS` | 10 / 02 / 03 / 456 |
    /// | `zzz` / `xxx` | JST / +09:00 |
    ///
    /// それ以外の英字（`YYYY` `hh` `a` など）は bug!。
    ///
    pub def pattern(spec: String): List[Format] =
        patternLoop(String.toList(spec), Nil) |> List.reverse

    def patternLoop(chars: List[Char], acc: List[Format]): List[Format] = match chars {
        case Nil => acc
        case '\'' :: rest =>
            let (quoted, afterQuote) = List.span(c -> c != '\'', rest);
            patternLoop(List.drop(1, afterQuote), Format.Text(charsToString(quoted)) :: acc)
        case c :: _ if Char.isLetter(c) =>
            let (same, rest) = List.span(x -> x == c, chars);
            patternLoop(rest, letterToken(c, List.length(same)) :: acc)
        case c :: rest =>
            let (symbols, afterSymbols) = List.span(x -> not Char.isLetter(x) and x != '\'', c :: rest);
            patternLoop(afterSymbols, Format.Text(charsToString(symbols)) :: acc)
    }

    def charsToString(chars: List[Char]): String = chars |> List.map(ToString.toString) |> List.join("")

    def letterToken(letter: Char, count: Int32): Format = match (letter, count) {
        case ('y', 4) => Format.Year
        case ('M', 1) => Format.Month
        case ('M', 2) => Format.Month2
        case ('M', 4) => Format.MonthName
        case ('d', 1) => Format.Day
        case ('d', 2) => Format.Day2
        case ('E', 4) => Format.Weekday
        case ('H', 2) => Format.Hour2
        case ('m', 2) => Format.Minute2
        case ('s', 2) => Format.Second2
        case ('S', 3) => Format.Millis3
        case ('z', 3) => Format.ZoneName
        case ('x', 3) => Format.Offset
        case _ => bug!("Format.pattern: '${String.repeat(count, "${letter}")}' は使えない（yyyy M MM MMMM d dd EEEE HH mm ss SSS zzz xxx）")
    }

    ///
    /// `2026-09-06`
    ///
    pub def iso8601Date(): List[Format] =
        List#{Format.Year, Format.Text("-"), Format.Month2, Format.Text("-"), Format.Day2}

    ///
    /// `2026-09-06 10:00`
    ///
    pub def iso8601Minute(): List[Format] =
        List.append(iso8601Date(), List#{Format.Text(" "), Format.Hour2, Format.Text(":"), Format.Minute2})

    ///
    /// `2026-09-06 10:00:00`
    ///
    pub def iso8601Second(): List[Format] =
        List.append(iso8601Minute(), List#{Format.Text(":"), Format.Second2})

    ///
    /// 暦の各値を受けてトークンを文字にする。Timestamp と Date が共有する。
    ///
    /// - `weekday`: 1 = 月曜 … 7 = 日曜（ISO）
    /// - `zoneName` / `offset`: Date には無いので空文字
    ///
    pub type alias Fields = { year = Int32, month = Int32, day = Int32, weekday = Int32, hour = Int32, minute = Int32, second = Int32, millis = Int32, zoneName = String, offset = String }

    pub def render(tokens: List[Format], fields: Fields): String =
        tokens |> List.map(token -> renderToken(token, fields)) |> List.join("")

    def renderToken(token: Format, fields: Fields): String = match token {
        case Format.Year => pad(4, fields#year)
        case Format.Month => "${fields#month}"
        case Format.Month2 => pad(2, fields#month)
        case Format.MonthName => monthName(fields#month)
        case Format.Day => "${fields#day}"
        case Format.Day2 => pad(2, fields#day)
        case Format.Weekday => weekdayName(fields#weekday)
        case Format.Hour2 => pad(2, fields#hour)
        case Format.Minute2 => pad(2, fields#minute)
        case Format.Second2 => pad(2, fields#second)
        case Format.Millis3 => pad(3, fields#millis)
        case Format.ZoneName => fields#zoneName
        case Format.Offset => fields#offset
        case Format.Text(text) => text
    }

    def pad(width: Int32, value: Int32): String =
        if (value < 0) "-" + String.padLeft(width, '0', "${-value}") else String.padLeft(width, '0', "${value}")

    def monthName(month: Int32): String = match month {
        case 1 => "January"
        case 2 => "February"
        case 3 => "March"
        case 4 => "April"
        case 5 => "May"
        case 6 => "June"
        case 7 => "July"
        case 8 => "August"
        case 9 => "September"
        case 10 => "October"
        case 11 => "November"
        case 12 => "December"
        case _ => bug!("Format: month ${month}")
    }

    def weekdayName(weekday: Int32): String = match weekday {
        case 1 => "Monday"
        case 2 => "Tuesday"
        case 3 => "Wednesday"
        case 4 => "Thursday"
        case 5 => "Friday"
        case 6 => "Saturday"
        case 7 => "Sunday"
        case _ => bug!("Format: weekday ${weekday}")
    }

}
