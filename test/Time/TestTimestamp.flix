use Format.Format

// Timestamp: ISO 8601 の往復、算術、TimeZone を通した暦の読み出しと表示。

def tokyo(): Zone.Zone = Zone.fromName("Asia/Tokyo") |> Option.getWithDefault(Zone.utc())

def at(iso: String): Timestamp.Timestamp = Timestamp.fromIso8601(iso) |> Option.getWithDefault(Timestamp.fromEpochMicros(0i64))

/// ISO 8601 の parse は offset を UTC に畳む。offset 無しと壊れた形は None。
///
///   2026-09-06T10:00:00+09:00 == 2026-09-06T01:00:00Z / マイクロ秒も保つ / 1970 年より前も往復
@Test
def testIso8601RoundTrip(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{"2026-09-06T01:00:00Z", "2026-09-06T01:00:00.123456Z", "1969-12-31T23:59:59.999Z", "None", "None"},
        List#{
            Timestamp.toIso8601(at("2026-09-06T10:00:00+09:00")),
            Timestamp.toIso8601(at("2026-09-06T01:00:00.123456Z")),
            Timestamp.toIso8601(at("1969-12-31T23:59:59.999Z")),
            "${Timestamp.fromIso8601("2026-09-06T10:00:00")}",
            "${Timestamp.fromIso8601("not a time")}"
        })

/// epoch ミリ秒との往復と、Duration の加減算。
@Test
def testArithmetic(): Unit \ Assert =
    let base = at("2026-09-06T00:00:00Z");
    Assert.assertEq(
        expected = ("2026-09-13T00:00:00Z", "2026-09-05T23:59:00Z", 604800i64, 1788652800000i64),
        (Timestamp.toIso8601(base |> Timestamp.plus(Time.Duration.days(7))),
         Timestamp.toIso8601(base |> Timestamp.minus(Time.Duration.minutes(1))),
         Time.Duration.toSeconds(Timestamp.between(base, base |> Timestamp.plus(Time.Duration.days(7)))),
         Timestamp.toEpochMillis(base)))

/// toCivil は TimeZone のゾーンで暦を読む。同じ瞬間でも東京と UTC で日付が変わる。
///
///   2026-09-05T20:00:00Z → 東京 9/6 05:00 / UTC 9/5 20:00
@Test
def testToCivilDependsOnZone(): Unit \ Assert =
    let t = at("2026-09-05T20:00:00Z");
    let inTokyo = TimeZone.runWith(tokyo(), () -> Timestamp.toCivil(t));
    let inUtc = TimeZone.runWith(Zone.utc(), () -> Timestamp.toCivil(t));
    Assert.assertEq(
        expected = (("2026-09-06", 5), ("2026-09-05", 20)),
        ((Date.toIso8601(inTokyo#date), inTokyo#hour), (Date.toIso8601(inUtc#date), inUtc#hour)))

/// fromCivil は toCivil の逆。夏時間の隙間（ニューヨーク 2026-03-08 02:30）は None。
@Test
def testFromCivil(): Unit \ Assert =
    let newYork = Zone.fromName("America/New_York") |> Option.getWithDefault(Zone.utc());
    let civil = { date = Date.fromYmd({ year = 2026, month = 9, day = 6 }) |> Option.getWithDefault(Date.fromEpochDay(0)), hour = 10, minute = 30, second = 0, micro = 0 };
    let gap = { date = Date.fromYmd({ year = 2026, month = 3, day = 8 }) |> Option.getWithDefault(Date.fromEpochDay(0)), hour = 2, minute = 30, second = 0, micro = 0 };
    Assert.assertEq(
        expected = (Some("2026-09-06T01:30:00Z"), None),
        (TimeZone.runWith(tokyo(), () -> Timestamp.fromCivil(civil)) |> Option.map(Timestamp.toIso8601),
         TimeZone.runWith(newYork, () -> Timestamp.fromCivil(gap))))

/// format は全トークンをゾーン込みで出す。
///
///   2026-09-06T01:02:03.456Z を東京で → 2026-09-06 10:02:03.456 September Sunday JST +09:00
@Test
def testFormatTokens(): Unit \ Assert =
    let t = at("2026-09-06T01:02:03.456Z");
    let tokens = List#{
        Format.Year, Format.Text("-"), Format.Month2, Format.Text("-"), Format.Day2, Format.Text(" "),
        Format.Hour2, Format.Text(":"), Format.Minute2, Format.Text(":"), Format.Second2, Format.Text("."), Format.Millis3, Format.Text(" "),
        Format.MonthName, Format.Text(" "), Format.Weekday, Format.Text(" "), Format.ZoneName, Format.Text(" "), Format.Offset
    };
    Assert.assertEq(
        expected = ("2026-09-06 10:02:03.456 September Sunday JST +09:00", "2026-09-06 01:02", "+00:00"),
        (TimeZone.runWith(tokyo(), () -> Timestamp.format(tokens, t)),
         TimeZone.runWith(Zone.utc(), () -> Timestamp.format(Format.iso8601Minute(), t)),
         TimeZone.runWith(Zone.utc(), () -> Timestamp.format(List#{Format.Offset}, t))))

/// runFrozen は now と today を止める。今が 2026-09-05T20:00:00Z なら、東京の今日は 9/6。
@Test
def testRunFrozen(): Unit \ Assert =
    let (now, today) = TimeTest.runFrozen({ now = "2026-09-05T20:00:00Z", zone = tokyo() }, () -> (Timestamp.now(), Date.today()));
    Assert.assertEq(expected = ("2026-09-05T20:00:00Z", "2026-09-06"), (Timestamp.toIso8601(now), Date.toIso8601(today)))

/// 無いゾーン名は None。
@Test
def testZoneFromName(): Unit \ Assert =
    Assert.assertEq(
        expected = (true, false),
        (Option.nonEmpty(Zone.fromName("Asia/Tokyo")), Option.nonEmpty(Zone.fromName("Mars/Olympus"))))
