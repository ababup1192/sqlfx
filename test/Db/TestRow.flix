use SqlValue.SqlValue

// Row: 列名 → 添字の共有インデックスと、列名での取り出し。


/// makeRows は列名を添字に変え、全行で同じ ColumnIndex を持つ。
///
///   names:  id | name
///   row 0:   1 | alice
///   row 1:   2 | bob
@Test
def testMakeRowsSharesColumnIndex(): Unit \ Assert =
    let rows = Row.makeRows(
        List#{"id", "name"},
        List#{
            List#{SqlValue.Int64(1i64), SqlValue.Str("alice")},
            List#{SqlValue.Int64(2i64), SqlValue.Str("bob")}
        });
    Assert.assertEq(
        expected = List#{Map#{"id" => 0, "name" => 1}, Map#{"id" => 0, "name" => 1}},
        rows |> List.map(row -> row#columns))

/// get は列名で値を返し、無い列は None。
@Test
def testGetByName(): Unit \ Assert =
    let row = Row.makeRows(List#{"id", "name"}, List#{List#{SqlValue.Int64(1i64), SqlValue.Str("alice")}})
        |> List.head
        |> Option.getWithDefault({ columns = Map#{}, cells = Vector#{} });
    Assert.assertEq(
        expected = (Some(SqlValue.Str("alice")), None),
        (Row.get("name", row), Row.get("missing", row)))

/// columnNames は添字の順で列名を返す。
@Test
def testColumnNamesInIndexOrder(): Unit \ Assert =
    let row = { columns = Row.makeColumnIndex(List#{"z", "a", "m"}), cells = Vector#{} };
    Assert.assertEq(expected = List#{"z", "a", "m"}, Row.columnNames(row))
