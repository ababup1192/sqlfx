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

/// 並び順。Unordered は空文字、thenAsc / thenDesc でキーを足す。
@Test
def testRenderOrder(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{"", "ORDER BY name ASC, age DESC"},
        List#{Fragment.renderOrder(Fragment.unordered()), Fragment.renderOrder(Fragment.asc(nameCol()) |> Fragment.thenDesc(ageCol()))})

// ---- SET 句（Changes）----

/// 代入は積んだ順に `col = $n` で並び、$n は既にある引数の続き番号。NULL はリテラル、increment は `col = col + $n`。
@Test
def testAppendChanges(): Unit \ Assert =
    let changes = Fragment.noChange()
        |> Fragment.set(nameCol(), "a")
        |> Fragment.setNull(deletedAtCol())
        |> Fragment.increment(ageCol(), 2);
    Assert.assertEq(
        expected = ("name = $2, deleted_at = NULL, age = age + $3", List#{SqlValue.Int64(9i64), SqlValue.Str("a"), SqlValue.Int32(2)}),
        Fragment.appendChanges(changes, List#{SqlValue.Int64(9i64)}))

/// setIfSome は None なら何も積まない。setOrNull は None なら NULL。
@Test
def testSetIfSomeAndSetOrNull(): Unit \ Assert =
    let changes = Fragment.noChange()
        |> Fragment.setIfSome(nameCol(), None)
        |> Fragment.setIfSome(ageCol(), Some(3))
        |> Fragment.setOrNull(deletedAtCol(), None);
    Assert.assertEq(
        expected = ("age = $1, deleted_at = NULL", List#{SqlValue.Int32(3)}),
        Fragment.appendChanges(changes, Nil))

/// 同じ列を 2 回代入したら後の物だけ、後の位置に出る。
@Test
def testChangesLastWins(): Unit \ Assert =
    let changes = Fragment.noChange()
        |> Fragment.set(nameCol(), "first")
        |> Fragment.set(ageCol(), 1)
        |> Fragment.set(nameCol(), "second");
    Assert.assertEq(
        expected = ("age = $1, name = $2", List#{SqlValue.Int32(1), SqlValue.Str("second")}),
        Fragment.appendChanges(changes, Nil))

/// 何も積まなければ空。setIfSome の None だけでも空。
@Test
def testEmptyChanges(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{true, true, false},
        List#{
            Fragment.isEmptyChanges(Fragment.noChange()),
            Fragment.isEmptyChanges(Fragment.noChange() |> Fragment.setIfSome(nameCol(), None)),
            Fragment.isEmptyChanges(Fragment.noChange() |> Fragment.set(nameCol(), "a"))
        })

/// rawSet は RawSql が要り、そのまま出る。同じ列でも畳まない。
@Test
def testRawSet(): Unit \ Assert =
    let changes = RawSql.runWithAllow(() -> Fragment.noChange() |> Fragment.set(ageCol(), 0) |> Fragment.rawSet("age = age * 2"));
    Assert.assertEq(expected = ("age = $1, age = age * 2", List#{SqlValue.Int32(0)}), Fragment.appendChanges(changes, Nil))

/// パラメータ付きの生 SQL は ? が続き番号の $n になり、値はプレースホルダに積まれる。
@Test
def testRawPredWith(): Unit \ Assert =
    let rendered = run {
        Fragment.renderPred(Fragment.both(Fragment.rawPredWith("a = ? AND b = ?", List#{SqlValue.Int32(1), SqlValue.Str("x")}), Fragment.rawPredWith("c = ?", List#{SqlValue.Bool(true)})), 3)
    } with RawSql.runWithAllow;
    Assert.assertEq(expected = ("((a = $3 AND b = $4) AND (c = $5))", List#{SqlValue.Int32(1), SqlValue.Str("x"), SqlValue.Bool(true)}), rendered)

/// 生 SQL は RawSql が要り、render では括弧に包まれる。
@Test
def testRawPred(): Unit \ Assert =
    let rendered = run {
        Fragment.renderPred(Fragment.rawPred("age > 1"), 1)
    } with RawSql.runWithAllow;
    Assert.assertEq(expected = ("(age > 1)", Nil), rendered)
