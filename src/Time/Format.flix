///
/// 日時の書式。文字列でなくトークンの List で並べる。
///
/// WhyNot: `"yyyy-MM-dd"` のような書式文字列を受けないのは、`YYYY`（週年）や `hh`（12 時間）の取り違えが
/// 実行するまで分からないから。トークンなら存在しない指定が型で消える。
///
mod Format {

    pub enum Format with Eq, Order, ToString {
        /// 2026
        case Year
        /// 09
        case Month2
        /// September
        case MonthName
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
        case Format.Month2 => pad(2, fields#month)
        case Format.MonthName => monthName(fields#month)
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
