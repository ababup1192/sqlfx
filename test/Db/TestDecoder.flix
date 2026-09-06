use SqlValue.SqlValue
use Decoder.DecodeError

// Decoder: 列を型付きで取り出し、複数列をレコードへ組む。


/// テスト用の 1 行。
///
///   id | name  | age  | score
///    1 | alice | NULL | 1.5
def sampleRow(): Row.Row =
    Row.makeRows(
        List#{"id", "name", "age", "score"},
        List#{List#{SqlValue.Int64(1i64), SqlValue.Str("alice"), SqlValue.Null, SqlValue.Decimal(1.5ff)}})
        |> List.head
        |> Option.getWithDefault({ columns = Map#{}, cells = Vector#{} })

// ---- 列 1 つ ----

/// int64 / str は列を型付きで返す。
@Test
def testTypedColumns(): Unit \ Assert =
    Assert.assertEq(
        expected = (Ok(1i64), Ok("alice"), Ok(1.5ff)),
        (
            Decoder.decodeRow(Decoder.int64("id"), sampleRow()),
            Decoder.decodeRow(Decoder.str("name"), sampleRow()),
            Decoder.decodeRow(Decoder.decimal("score"), sampleRow())
        ))

/// 無い列は MissingColumn。
@Test
def testMissingColumn(): Unit \ Assert =
    Assert.assertEq(
        expected = Err(DecodeError.MissingColumn("email")),
        Decoder.decodeRow(Decoder.str("email"), sampleRow()))

/// 型が違う列は TypeMismatch（列名・期待した型・実際の型）。
@Test
def testTypeMismatch(): Unit \ Assert =
    Assert.assertEq(
        expected = Err(DecodeError.TypeMismatch("name", "Int64", "Str")),
        Decoder.decodeRow(Decoder.int64("name"), sampleRow()))

/// NULL を許さないデコーダに NULL が来たら UnexpectedNull。
@Test
def testUnexpectedNull(): Unit \ Assert =
    Assert.assertEq(
        expected = Err(DecodeError.UnexpectedNull("age")),
        Decoder.decodeRow(Decoder.int32("age"), sampleRow()))

/// opt は NULL を None に、値を Some にする。型違いはそのままエラー。
@Test
def testOpt(): Unit \ Assert =
    Assert.assertEq(
        expected = (Ok(None), Ok(Some("alice")), Err(DecodeError.TypeMismatch("name", "Int64", "Str"))),
        (
            Decoder.decodeRow(Decoder.opt(Decoder.int32("age")), sampleRow()),
            Decoder.decodeRow(Decoder.opt(Decoder.str("name")), sampleRow()),
            Decoder.decodeRow(Decoder.opt(Decoder.int64("name")), sampleRow())
        ))

// ---- 合成 ----

/// pure + ap で複数列を 1 つのレコードへ組む。
@Test
def testApBuildsRecord(): Unit \ Assert =
    let decoder =
        Decoder.pure(id -> name -> age -> { id = id, name = name, age = age })
            |> Decoder.ap(Decoder.int64("id"))
            |> Decoder.ap(Decoder.str("name"))
            |> Decoder.ap(Decoder.opt(Decoder.int32("age")));
    Assert.assertEq(
        expected = Ok((1i64, "alice", None)),
        Decoder.decodeRow(decoder, sampleRow()) |> Result.map(user -> (user#id, user#name, user#age)))

/// ap の途中で失敗したら、その列のエラーで止まる。
@Test
def testApStopsAtFirstError(): Unit \ Assert =
    let decoder =
        Decoder.pure(id -> email -> (id, email))
            |> Decoder.ap(Decoder.int64("id"))
            |> Decoder.ap(Decoder.str("email"));
    Assert.assertEq(
        expected = Err(DecodeError.MissingColumn("email")),
        Decoder.decodeRow(decoder, sampleRow()))

/// map はデコード結果を変換する。
@Test
def testMap(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok("ALICE"),
        Decoder.decodeRow(Decoder.str("name") |> Decoder.map(String.toUpperCase), sampleRow()))

/// decodeRows は全行を順にデコードし、失敗した行のエラーを返す。
///
///   id
///    1
///   "x"  ← 2 行目で型違い
@Test
def testDecodeRowsFirstError(): Unit \ Assert =
    let rows = Row.makeRows(List#{"id"}, List#{List#{SqlValue.Int64(1i64)}, List#{SqlValue.Str("x")}});
    Assert.assertEq(
        expected = (Ok(List#{1i64}), Err(DecodeError.TypeMismatch("id", "Int64", "Str"))),
        (
            Decoder.decodeRows(Decoder.int64("id"), List.take(1, rows)),
            Decoder.decodeRows(Decoder.int64("id"), rows)
        ))

/// describeError は列名を含む 1 行のメッセージを返す。
@Test
def testDescribeError(): Unit \ Assert =
    Assert.assertEq(
        expected = "column 'name' is Str, expected Int64",
        Decoder.describeError(DecodeError.TypeMismatch("name", "Int64", "Str")))

// ---- SELECT 句 ----

/// forA に並べた順で SELECT 句の断片が並び、pure |> ap で組んでも同じ。opt は列を変えない。
@Test
def testSelectListFollowsForAOrder(): Unit \ Assert =
    let viaForA = forA (
        id <- Decoder.int64("id");
        name <- Decoder.str("name");
        email <- Decoder.opt(Decoder.str("email"))
    ) yield (id, name, email);
    let viaAp = Decoder.pure(id -> name -> email -> (id, name, email))
        |> Decoder.ap(Decoder.int64("id"))
        |> Decoder.ap(Decoder.str("name"))
        |> Decoder.ap(Decoder.opt(Decoder.str("email")));
    Assert.assertEq(
        expected = (List#{"id", "name", "email"}, "id, name, email"),
        (Decoder.selectList(viaForA), Decoder.selectClause(viaAp)))

/// selectExpr は式を `expr AS label` として SELECT 句に出し、読むのはラベルの列。同じ列を 2 回読んでも SELECT 句には 1 回。
@Test
def testSelectExprAndDedupe(): Unit \ Assert =
    let count = Decoder.selectExpr("count(*)::bigint", Decoder.int64("total"));
    let twice = forA (a <- Decoder.int64("id"); b <- Decoder.int64("id")) yield a + b;
    let row = Row.makeRows(List#{"total"}, List#{List#{SqlValue.Int64(3i64)}}) |> List.head |> Option.getWithDefault({ columns = Map#{}, cells = Vector#{} });
    Assert.assertEq(
        expected = (List#{"count(*)::bigint AS total"}, Ok(3i64), List#{"id"}),
        (Decoder.selectList(count), Decoder.decodeRow(count, row), Decoder.selectList(twice)))
