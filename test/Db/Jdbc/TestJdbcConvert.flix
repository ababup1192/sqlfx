use SqlValue.SqlValue

// JdbcConvert: `$n` → `?` の書き換え（純粋）。

/// `$1` `$2` は出現順に `?` になり、パラメータは出現順に並ぶ。
@Test
def testRewriteInOrder(): Unit \ Assert =
    Assert.assertEq(
        expected = Some(("SELECT * FROM t WHERE a = ? AND b = ?", List#{SqlValue.Int64(1i64), SqlValue.Str("x")})),
        JdbcConvert.rewritePlaceholders("SELECT * FROM t WHERE a = $1 AND b = $2", List#{SqlValue.Int64(1i64), SqlValue.Str("x")}))

/// 同じ `$1` を 2 回使えば値も 2 回並ぶ。順序が逆でも値は `$n` に従う。
@Test
def testRewriteRepeatAndReorder(): Unit \ Assert =
    Assert.assertEq(
        expected = Some(("? ? ?", List#{SqlValue.Str("b"), SqlValue.Str("a"), SqlValue.Str("b")})),
        JdbcConvert.rewritePlaceholders("$2 $1 $2", List#{SqlValue.Str("a"), SqlValue.Str("b")}))

/// 文字列リテラルの中の `$1` と、数字が続かない `$` は触らない。2 桁の `$10` も読める。
@Test
def testRewriteSkipsQuotesAndBareDollar(): Unit \ Assert =
    let params = List.range(1, 11) |> List.map(i -> SqlValue.Int32(i));
    Assert.assertEq(
        expected = Some(("SELECT '$1', $$, ?", List#{SqlValue.Int32(10)})),
        JdbcConvert.rewritePlaceholders("SELECT '$1', $$, $10", params))

/// params に無い `$n` は None。
@Test
def testRewriteOutOfRange(): Unit \ Assert =
    Assert.assertEq(expected = None, JdbcConvert.rewritePlaceholders("SELECT $2", List#{SqlValue.Int32(1)}))
