// Uuid: 形式の検証と random の形。

/// 36 文字の形だけ通り、小文字に揃う。
@Test
def testFromString(): Unit \ Assert =
    Assert.assertEq(
        expected = (Some("550e8400-e29b-41d4-a716-446655440000"), None),
        (Uuid.fromString("550E8400-E29B-41D4-A716-446655440000") |> Option.map(Uuid.toText), Uuid.fromString("nope")))

/// random は毎回違い、fromString で読み戻せる形。
@Test
def testRandom(): Unit \ {Assert, NonDet} =
    let first = Uuid.random();
    let second = Uuid.random();
    Assert.assertEq(expected = (true, true), (first != second, Option.nonEmpty(Uuid.fromString(Uuid.toText(first)))))
