use SqlValue.SqlValue

// Fragment: 断片 DSL の組み立てと render。

/// テスト用のテーブル印と列。生成器が吐く物と同じ形。
enum T { case T }
def nameCol(): Fragment.Col[T, String] = Fragment.Col.Col("name", SqlValue.Str)
def ageCol(): Fragment.Col[T, Int32] = Fragment.Col.Col("age", SqlValue.Int32)
def deletedAtCol(): Fragment.Col[T, Int64] = Fragment.Col.Col("deleted_at", SqlValue.Timestamp)

/// 述語は括弧全付けで、値は出現順の $n になる。firstIndex から番号が始まる。
///
///   (deleted_at IS NULL) AND ((name LIKE $3) OR (age >= $4))  ← $1, $2 は本文側の引数
@Test
def testRenderPred(): Unit \ Assert =
    let pred = Fragment.both(
        Fragment.isNull(deletedAtCol()),
        Fragment.either(Fragment.like(nameCol(), "a%"), Fragment.ge(ageCol(), 20)));
    Assert.assertEq(
        expected = ("((deleted_at IS NULL) AND ((name LIKE $3) OR (age >= $4)))", List#{SqlValue.Str("a%"), SqlValue.Int32(20)}),
        Fragment.renderPred(pred, 3))

/// when が偽なら TRUE、IN の空は FALSE、IN は値の数だけ $n、NOT は括弧で包む。all は always を消して繋ぎ、any は OR。
@Test
def testRenderPredEdges(): Unit \ Assert =
    let rendered = List#{
        Fragment.renderPred(Fragment.when(false, Fragment.eq(ageCol(), 1)), 1),
        Fragment.renderPred(Fragment.inList(ageCol(), Nil), 1),
        Fragment.renderPred(Fragment.inList(ageCol(), List#{1, 2}), 5),
        Fragment.renderPred(Fragment.negate(Fragment.isNotNull(nameCol())), 1),
        Fragment.renderPred(Fragment.all(Nil), 1),
        Fragment.renderPred(Fragment.all(List#{Fragment.always(), Fragment.eq(ageCol(), 1), Fragment.when(false, Fragment.isNull(nameCol()))}), 1),
        Fragment.renderPred(Fragment.any(List#{Fragment.eq(ageCol(), 1), Fragment.eq(ageCol(), 2)}), 1),
        Fragment.renderPred(Fragment.any(Nil), 1)
    };
    Assert.assertEq(expected = List#{
        ("TRUE", Nil),
        ("FALSE", Nil),
        ("(age IN ($5, $6))", List#{SqlValue.Int32(1), SqlValue.Int32(2)}),
        ("(NOT (name IS NOT NULL))", Nil),
        ("TRUE", Nil),
        ("(age = $1)", List#{SqlValue.Int32(1)}),
        ("((age = $1) OR (age = $2))", List#{SqlValue.Int32(1), SqlValue.Int32(2)}),
        ("TRUE", Nil)
    }, rendered)

/// appendPred は既にある引数の後ろに続き番号で繋ぐ。
@Test
def testAppendPred(): Unit \ Assert =
    Assert.assertEq(
        expected = ("(age = $2)", List#{SqlValue.Str("x"), SqlValue.Int32(3)}),
        Fragment.appendPred(Fragment.eq(ageCol(), 3), List#{SqlValue.Str("x")}))

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
