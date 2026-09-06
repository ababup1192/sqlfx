///
/// テスト用。時刻とゾーンを止めて thunk を走らせる。
///
mod TimeTest {

    use Time.TimeUnit
    use Time.Clock

    ///
    /// - `now`: ISO 8601 の瞬間。形が違えば bug!
    /// - `zone`: 暦のゾーン
    ///
    pub type alias Frozen = { now = String, zone = Zone.Zone }

    pub def runFrozen(frozen: Frozen, thunk: Unit -> a \ ef): a \ ef - {Clock, TimeZone} =
        let micros = match Timestamp.fromIso8601(frozen#now) {
            case Some(t) => Timestamp.toEpochMicros(t)
            case None => bug!("TimeTest.runFrozen: not ISO 8601: ${frozen#now}")
        };
        run {
            thunk()
        } with handler Clock {
            def currentTime(unit, resume) = resume(convert(micros, unit))
        } with TimeZone.runWith(frozen#zone)

    def convert(micros: Int64, unit: TimeUnit): Int64 =
        let duration = Time.Duration.nanoseconds(micros * 1000i64);
        match unit {
            case TimeUnit.Nanoseconds => Time.Duration.toNanos(duration)
            case TimeUnit.Microseconds => micros
            case TimeUnit.Milliseconds => Time.Duration.toMillis(duration)
            case TimeUnit.Seconds => Time.Duration.toSeconds(duration)
            case TimeUnit.Minutes => Time.Duration.toMinutes(duration)
            case TimeUnit.Hours => Time.Duration.toHours(duration)
            case TimeUnit.Days => Time.Duration.toDays(duration)
        }

}
