use SqlValue.SqlValue
use Fragment.{===, =!=, <<, <<=, >>, >>=}

// Fragment: 断片 DSL の組み立てと render。

/// テスト用のテーブル印と列。生成器が吐く物と同じ形。
enum T { case T }
def nameCol(): Fragment.Col[T, String, Fragment.NotNull] = Fragment.Col.Col("name", SqlValue.Str)
def ageCol(): Fragment.Col[T, Int32, Fragment.NotNull] = Fragment.Col.Col("age", SqlValue.Int32)
def createdAtCol(): Fragment.Col[T, Int64, Fragment.NotNull] = Fragment.Col.Col("created_at", SqlValue.Timestamp)
def deletedAtCol(): Fragment.Col[T, Int64, Fragment.Nullable] = Fragment.Col.Col("deleted_at", SqlValue.Timestamp)

/// 述語は括弧全付けで、値は出現順の $n になる。firstIndex から番号が始まる。
///
///   (deleted_at IS NULL) AND ((name LIKE $3) OR (age >= $4))  ← $1, $2 は本文側の引数
@Test
def testRenderPred(): Unit \ Assert =
    let pred = Fragment.both(
        Fragment.isNull(deletedAtCol()),
        Fragment.either(Fragment.like(nameCol(), "a%"), ageCol() >>= Fragment.value(20)));
    Assert.assertEq(
        expected = ("((deleted_at IS NULL) AND ((name LIKE $3) OR (age >= $4)))", List#{SqlValue.Str("a%"), SqlValue.Int32(20)}),
        Fragment.renderPred(pred, 3))

/// when が偽なら TRUE、IN の空は FALSE、IN は値の数だけ $n、NOT は括弧で包む。all は always を消して繋ぎ、any は OR。
@Test
def testRenderPredEdges(): Unit \ Assert =
    let rendered = List#{
        Fragment.renderPred(Fragment.when(false, ageCol() === Fragment.value(1)), 1),
        Fragment.renderPred(Fragment.inList(ageCol(), Nil), 1),
        Fragment.renderPred(Fragment.inList(ageCol(), List#{1, 2}), 5),
        Fragment.renderPred(Fragment.negate(Fragment.isNotNull(deletedAtCol())), 1),
        Fragment.renderPred(Fragment.all(Nil), 1),
        Fragment.renderPred(Fragment.all(List#{Fragment.always(), ageCol() === Fragment.value(1), Fragment.when(false, Fragment.isNull(deletedAtCol()))}), 1),
        Fragment.renderPred(Fragment.any(List#{ageCol() === Fragment.value(1), ageCol() === Fragment.value(2)}), 1),
        Fragment.renderPred(Fragment.any(Nil), 1)
    };
    Assert.assertEq(expected = List#{
        ("TRUE", Nil),
        ("FALSE", Nil),
        ("(age IN ($5, $6))", List#{SqlValue.Int32(1), SqlValue.Int32(2)}),
        ("(NOT (deleted_at IS NOT NULL))", Nil),
        ("TRUE", Nil),
        ("(age = $1)", List#{SqlValue.Int32(1)}),
        ("((age = $1) OR (age = $2))", List#{SqlValue.Int32(1), SqlValue.Int32(2)}),
        ("TRUE", Nil)
    }, rendered)

/// 列同士の比較は演算子 6 つ。値を積まないので引数は空。nullability が違う列同士でも組める。
/// 同じ演算子の右辺に value を置くと $n になる。
@Test
def testCompareCols(): Unit \ Assert =
    let rendered = List#{
        Fragment.renderPred(deletedAtCol() === createdAtCol(), 1),
        Fragment.renderPred(deletedAtCol() =!= createdAtCol(), 1),
        Fragment.renderPred(deletedAtCol() << createdAtCol(), 1),
        Fragment.renderPred(deletedAtCol() <<= createdAtCol(), 1),
        Fragment.renderPred(deletedAtCol() >> createdAtCol(), 1),
        Fragment.renderPred(deletedAtCol() >>= createdAtCol(), 1),
        Fragment.renderPred(ageCol() << Fragment.value(30), 1),
        Fragment.renderPred(ageCol() =!= Fragment.value(30), 1)
    };
    Assert.assertEq(expected = List#{
        ("(deleted_at = created_at)", Nil),
        ("(deleted_at <> created_at)", Nil),
        ("(deleted_at < created_at)", Nil),
        ("(deleted_at <= created_at)", Nil),
        ("(deleted_at > created_at)", Nil),
        ("(deleted_at >= created_at)", Nil),
        ("(age < $1)", List#{SqlValue.Int32(30)}),
        ("(age <> $1)", List#{SqlValue.Int32(30)})
    }, rendered)

/// 列同士の比較を値の比較と混ぜても、$n は値の分だけ進む。
///
///   (age >= $1) AND (deleted_at > created_at) AND (name = $2)
@Test
def testCompareColsKeepsPlaceholderIndex(): Unit \ Assert =
    let pred = Fragment.all(List#{ageCol() >>= Fragment.value(20), deletedAtCol() >> createdAtCol(), nameCol() === Fragment.value("a")});
    Assert.assertEq(
        expected = ("(((age >= $1) AND (deleted_at > created_at)) AND (name = $2))", List#{SqlValue.Int32(20), SqlValue.Str("a")}),
        Fragment.renderPred(pred, 1))

/// appendPred は既にある引数の後ろに続き番号で繋ぐ。
@Test
def testAppendPred(): Unit \ Assert =
    Assert.assertEq(
        expected = ("(age = $2)", List#{SqlValue.Str("x"), SqlValue.Int32(3)}),
        Fragment.appendPred(ageCol() === Fragment.value(3), List#{SqlValue.Str("x")}))

/// 並び順。Unordered は空文字、then で繋ぐ。
@Test
def testRenderOrder(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{"", "ORDER BY name ASC, age DESC"},
        List#{Fragment.renderOrder(Fragment.unordered()), Fragment.renderOrder(Fragment.then(Fragment.asc(nameCol()), Fragment.desc(ageCol())))})

/// 生 SQL は RawSql が要り、render では括弧に包まれる。
@Test
def testRawPred(): Unit \ Assert =
    let rendered = run {
        Fragment.renderPred(Fragment.rawPred("age > 1"), 1)
    } with RawSql.runWithAllow;
    Assert.assertEq(expected = ("(age > 1)", Nil), rendered)
