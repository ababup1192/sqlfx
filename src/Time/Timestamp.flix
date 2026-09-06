///
/// UTC の瞬間。中身は epoch マイクロ秒。地域は持たず、暦日の読み出しと表示のときに `TimeZone` から受ける。
/// 瞬間同士の比較と算術は純粋、`now` は `Clock`、暦に触れる関数は `TimeZone`。
///
/// WhyNot: `OffsetDateTime` を表に出さないのは、Java 型を持つと `Eq` が derive できず、テストで値を書いて比較できないから。
/// WhyNot: `TIMESTAMP WITHOUT TIME ZONE` も同じ型に読むのは、ゾーンを持たない日時型を足すと「どちらで持つか」の判断が毎回要るから（chrono の Naive 系の事故）。
///
mod Timestamp {

    import java.time.Instant
    import java.time.ZoneId
    import java.time.ZonedDateTime
    import java.time.LocalDateTime
    import java.time.OffsetDateTime
    import java.time.DateTimeException
    import java.time.format.DateTimeFormatter
    import java.util.Locale

    use Time.TimeUnit
    use Time.Clock

    pub enum Timestamp(Int64) with Eq, Order

    instance ToString[Timestamp] {
        pub def toString(t: Timestamp): String = Timestamp.toIso8601(t)
    }

    ///
    /// 暦の値。`toCivil` が返し、`fromCivil` が受ける。
    ///
    /// - `date`: 暦日
    /// - `hour` / `minute` / `second`: 時刻
    /// - `micro`: 秒未満のマイクロ秒
    ///
    pub type alias Civil = { date = Date.Date, hour = Int32, minute = Int32, second = Int32, micro = Int32 }

    // ---- 純粋 ----

    pub def fromEpochMicros(micros: Int64): Timestamp = Timestamp.Timestamp(micros)

    pub def toEpochMicros(t: Timestamp): Int64 =
        let Timestamp.Timestamp(micros) = t;
        micros

    pub def fromEpochMillis(millis: Int64): Timestamp = Timestamp.Timestamp(millis * 1000i64)

    pub def toEpochMillis(t: Timestamp): Int64 = floorDiv(toEpochMicros(t), 1000i64)

    ///
    /// `"2026-09-06T10:00:00+09:00"` や `"2026-09-06T01:00:00Z"` から。offset の無い文字列は None。
    ///
    pub def fromIso8601(s: String): Option[Timestamp] =
        Unsafe.runPure(() -> try {
            let parsed: OffsetDateTime = OffsetDateTime.parse(s);
            Some(fromInstant(parsed.toInstant()))
        } catch {
            case _: DateTimeException => None
        })

    ///
    /// リテラル用。ISO 8601 でなければ bug!。テストや seed のように、値がコードに書いてある所で使う。
    ///
    pub def at(iso: String): Timestamp = match fromIso8601(iso) {
        case Some(t) => t
        case None => bug!("Timestamp.at: not ISO 8601: ${iso}")
    }

    ///
    /// UTC の ISO 8601。秒未満は 0 でなければマイクロ秒まで出す。
    ///
    pub def toIso8601(t: Timestamp): String =
        let instant = toInstant(t);
        Unsafe.runPure(() -> instant.toString())

    pub def plus(d: Time.Duration, t: Timestamp): Timestamp = Timestamp.Timestamp(toEpochMicros(t) + Time.Duration.toMicros(d))

    pub def minus(d: Time.Duration, t: Timestamp): Timestamp = Timestamp.Timestamp(toEpochMicros(t) - Time.Duration.toMicros(d))

    ///
    /// `start` から `end` までの長さ。`end` が前なら負。
    ///
    pub def between(start: {start = Timestamp}, end: {end = Timestamp}): Time.Duration =
        Time.Duration.nanoseconds((toEpochMicros(end#end) - toEpochMicros(start#start)) * 1000i64)

    // ---- 時計 ----

    pub def now(): Timestamp \ Clock = Timestamp.Timestamp(Clock.currentTime(TimeUnit.Microseconds))

    // ---- 暦（TimeZone）----

    ///
    /// 今のゾーンでの暦の値。
    ///
    pub def toCivil(t: Timestamp): Civil \ TimeZone =
        let zoned = toZoned(TimeZone.zone(), t);
        Unsafe.runPure(() -> {
            date = Date.fromEpochDay(Int64.clampToInt32(min = -2147483648, max = 2147483647, zoned.toLocalDate().toEpochDay())),
            hour = zoned.getHour(),
            minute = zoned.getMinute(),
            second = zoned.getSecond(),
            micro = zoned.getNano() / 1000
        })

    ///
    /// 暦の値から瞬間へ。夏時間の隙間に落ちる時刻は None。重なる時刻は早い方。
    ///
    pub def fromCivil(civil: Civil): Option[Timestamp] \ TimeZone =
        let zoneId = toZoneId(TimeZone.zone());
        let ymd = Date.toYmd(civil#date);
        Unsafe.runPure(() -> try {
            let local: LocalDateTime = LocalDateTime.of(ymd#year, ymd#month, ymd#day, civil#hour, civil#minute, civil#second, civil#micro * 1000);
            let zoned: ZonedDateTime = ZonedDateTime.of(local, zoneId);
            if (zoned.toLocalDateTime().equals(local)) Some(fromInstant(zoned.toInstant())) else None
        } catch {
            case _: DateTimeException => None
        })

    pub def toDate(t: Timestamp): Date.Date \ TimeZone = toCivil(t)#date

    ///
    /// 今のゾーンでの表示。
    ///
    pub def format(tokens: List[Format.Format], t: Timestamp): String \ TimeZone =
        let zoned = toZoned(TimeZone.zone(), t);
        let fields = Unsafe.runPure(() -> {
            year = zoned.getYear(),
            month = zoned.getMonthValue(),
            day = zoned.getDayOfMonth(),
            weekday = zoned.getDayOfWeek().getValue(),
            hour = zoned.getHour(),
            minute = zoned.getMinute(),
            second = zoned.getSecond(),
            millis = zoned.getNano() / 1000000,
            zoneName = DateTimeFormatter.ofPattern("zzz", Locale.ENGLISH).format(zoned),
            offset = offsetOf(zoned)
        });
        Format.render(tokens, fields)

    ///
    /// 負の値でも切り捨て（1970 年より前の瞬間で秒と秒未満の符号を揃える）。
    ///
    def floorDiv(x: Int64, n: Int64): Int64 = (x - Int64.modulo(x, n)) / n

    // ---- Java ----

    def fromInstant(instant: Instant): Timestamp =
        Unsafe.runPure(() -> Timestamp.Timestamp(instant.getEpochSecond() * 1000000i64 + Int32.toInt64(instant.getNano()) / 1000i64))

    def toInstant(t: Timestamp): Instant =
        let micros = toEpochMicros(t);
        let seconds = floorDiv(micros, 1000000i64);
        let nanos = Int64.modulo(micros, 1000000i64) * 1000i64;
        Unsafe.runPure(() -> Instant.ofEpochSecond(seconds, nanos))

    def toZoneId(zone: Zone.Zone): ZoneId =
        Unsafe.runPure(() -> ZoneId.of(Zone.toName(zone)))

    def toZoned(zone: Zone.Zone, t: Timestamp): ZonedDateTime =
        Unsafe.runPure(() -> ZonedDateTime.ofInstant(toInstant(t), toZoneId(zone)))

    ///
    /// `+09:00`。UTC は Java だと `Z` になるので `+00:00` に揃える。
    ///
    def offsetOf(zoned: ZonedDateTime): String =
        let id: String = Unsafe.runPure(() -> zoned.getOffset().getId());
        if (id == "Z") "+00:00" else id

}
