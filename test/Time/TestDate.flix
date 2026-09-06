use Format.Format

// Date: 年月日の検証、ISO 8601 の往復、日数の算術、表示。ゾーンには依存しない。

/// 2 月 30 日や 13 月は None。うるう日は Some。
@Test
def testFromYmd(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{Some("2024-02-29"), None, None, Some("1969-12-31")},
        List#{
            Date.fromYmd({ year = 2024, month = 2, day = 29 }) |> Option.map(Date.toIso8601),
            Date.fromYmd({ year = 2026, month = 2, day = 30 }) |> Option.map(Date.toIso8601),
            Date.fromYmd({ year = 2026, month = 13, day = 1 }) |> Option.map(Date.toIso8601),
            Date.fromYmd({ year = 1969, month = 12, day = 31 }) |> Option.map(Date.toIso8601)
        })

/// ISO 8601 の往復と toYmd。
@Test
def testIso8601AndYmd(): Unit \ Assert =
    let d = Date.fromIso8601("2026-09-06") |> Option.getWithDefault(Date.fromEpochDay(0));
    let ymd = Date.toYmd(d);
    Assert.assertEq(
        expected = ("2026-09-06", (2026, 9, 6), None, 20702),
        (Date.toIso8601(d), (ymd#year, ymd#month, ymd#day), Date.fromIso8601("2026/09/06"), Date.toEpochDay(d)))

/// 日数の加算と差、曜日（2026-09-06 は日曜 = 7）。
@Test
def testDayArithmetic(): Unit \ Assert =
    let d = Date.fromIso8601("2026-09-06") |> Option.getWithDefault(Date.fromEpochDay(0));
    Assert.assertEq(
        expected = ("2026-10-06", 30, 7, "September 06, Sunday"),
        (Date.toIso8601(d |> Date.plusDays(30)),
         Date.daysBetween(d, d |> Date.plusDays(30)),
         Date.weekday(d),
         Date.format(List#{Format.MonthName, Format.Text(" "), Format.Day2, Format.Text(", "), Format.Weekday}, d)))
