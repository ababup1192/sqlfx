use SqlValue.SqlValue

// SqlValue: 型ごとの取り出しと NULL 判定。


/// as* は同じ型の値だけ Some で返し、違う型は None。
@Test
def testAsSameType(): Unit \ Assert =
    Assert.assertEq(
        expected = (Some(1i64), Some("a"), Some(true), None),
        (
            SqlValue.asInt64(SqlValue.Int64(1i64)),
            SqlValue.asStr(SqlValue.Str("a")),
            SqlValue.asBool(SqlValue.Bool(true)),
            SqlValue.asStr(SqlValue.Int64(1i64))
        ))

/// asInt64 は Int32 の列（SERIAL）も広げて読める。
@Test
def testAsInt64WidensInt32(): Unit \ Assert =
    Assert.assertEq(expected = Some(7i64), SqlValue.asInt64(SqlValue.Int32(7)))

/// isNull は Null と NullOf が true。
@Test
def testIsNull(): Unit \ Assert =
    Assert.assertEq(
        expected = (true, true, false),
        (SqlValue.isNull(SqlValue.Null), SqlValue.isNull(SqlValue.NullOf(SqlValue.NullType.Str)), SqlValue.isNull(SqlValue.Str(""))))

/// ofOption: Some は wrap で包んだ値、None は型の付いた NULL。
///
///   Some("a") → Str("a") / None → NullOf(Str) / Some(Timestamp) → Timestamp(epoch micros)
@Test
def testOfOption(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{SqlValue.Str("a"), SqlValue.NullOf(SqlValue.NullType.Str), SqlValue.Timestamp(0i64), SqlValue.NullOf(SqlValue.NullType.Timestamp)},
        List#{
            SqlValue.ofOption(SqlValue.NullType.Str, SqlValue.Str, Some("a")),
            SqlValue.ofOption(SqlValue.NullType.Str, SqlValue.Str, None),
            SqlValue.ofOption(SqlValue.NullType.Timestamp, SqlValue.ofTimestamp, Some(Timestamp.fromEpochMicros(0i64))),
            SqlValue.ofOption(SqlValue.NullType.Timestamp, SqlValue.ofTimestamp, None)
        })

/// typeName はエラーメッセージ用の型名を返す。
@Test
def testTypeName(): Unit \ Assert =
    Assert.assertEq(
        expected = ("NULL", "NULL", "Int64Array"),
        (SqlValue.typeName(SqlValue.Null), SqlValue.typeName(SqlValue.NullOf(SqlValue.NullType.Int64)), SqlValue.typeName(SqlValue.Int64Array(Nil))))

/// SqlValue は Eq を持つので、テストハンドラが記録したパラメータを比較できる。
@Test
def testEq(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{SqlValue.Int64(1i64), SqlValue.Timestamp(0i64), SqlValue.Decimal(1.5ff)},
        List#{SqlValue.Int64(1i64), SqlValue.Timestamp(0i64), SqlValue.Decimal(1.5ff)})
