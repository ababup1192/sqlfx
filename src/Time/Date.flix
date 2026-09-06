///
/// 暦日。中身は 1970-01-01 からの日数。ゾーンを持たないので、比較・加算・表示は純粋。
/// 「今日」だけは `Clock` と `TimeZone` に依存する。
///
mod Date {

    import java.time.LocalDate
    import java.time.DateTimeException

    use Time.Clock

    pub enum Date(Int32) with Eq, Order

    instance ToString[Date] {
        pub def toString(d: Date): String = Date.toIso8601(d)
    }

    ///
    /// 年月日の組。
    ///
    pub type alias Ymd = { year = Int32, month = Int32, day = Int32 }

    pub def fromEpochDay(days: Int32): Date = Date.Date(days)

    pub def toEpochDay(d: Date): Int32 =
        let Date.Date(days) = d;
        days

    ///
    /// 年月日から。2 月 30 日のように存在しない日は None。
    ///
    pub def fromYmd(ymd: Ymd): Option[Date] =
        Unsafe.runPure(() -> try {
            let local: LocalDate = LocalDate.of(ymd#year, ymd#month, ymd#day);
            Some(fromLocal(local))
        } catch {
            case _: DateTimeException => None
        })

    pub def toYmd(d: Date): Ymd =
        let local = toLocal(d);
        Unsafe.runPure(() -> { year = local.getYear(), month = local.getMonthValue(), day = local.getDayOfMonth() })

    ///
    /// `"2026-09-06"` から。形が違えば None。
    ///
    pub def fromIso8601(s: String): Option[Date] =
        Unsafe.runPure(() -> try {
            let local: LocalDate = LocalDate.parse(s);
            Some(fromLocal(local))
        } catch {
            case _: DateTimeException => None
        })

    pub def toIso8601(d: Date): String = format(Format.iso8601Date(), d)

    pub def plusDays(n: Int32, d: Date): Date = Date.Date(toEpochDay(d) + n)

    pub def daysBetween(earlier: Date, later: Date): Int32 = toEpochDay(later) - toEpochDay(earlier)

    ///
    /// 表示。時刻とゾーンのトークンは空文字になる。
    ///
    pub def format(tokens: List[Format.Format], d: Date): String =
        let ymd = toYmd(d);
        Format.render(tokens, { year = ymd#year, month = ymd#month, day = ymd#day, weekday = weekday(d), hour = 0, minute = 0, second = 0, millis = 0, zoneName = "", offset = "" })

    ///
    /// 1 = 月曜 … 7 = 日曜。
    ///
    pub def weekday(d: Date): Int32 =
        let local = toLocal(d);
        Unsafe.runPure(() -> local.getDayOfWeek().getValue())

    ///
    /// 今のゾーンでの今日。
    ///
    pub def today(): Date \ {Clock, TimeZone} = Timestamp.toDate(Timestamp.now())

    def fromLocal(local: LocalDate): Date =
        let days: Int64 = Unsafe.runPure(() -> local.toEpochDay());
        Date.Date(Int64.clampToInt32(min = -2147483648, max = 2147483647, days))

    def toLocal(d: Date): LocalDate =
        Unsafe.runPure(() -> LocalDate.ofEpochDay(Int32.toInt64(toEpochDay(d))))

}
