use QueryDef.Segment
use QueryDef.SlotKind
use QueryDef.Shape

// QRender: AST から完全な SQL への機械置換。

/// :name は出現順の $n、{filter} は TRUE、{order} は空。同じ :name は同じ $n。
///
///   SELECT :a, :b, :a  {filter} {order}  →  SELECT $1, $2, $1  TRUE
@Test
def testToSql(): Unit \ Assert =
    let queryDef = {
        name = "q", params = Nil, shape = Shape.Many, keyed = None,
        slots = List#{ { name = "filter", kind = SlotKind.Pred, table = "t" }, { name = "order", kind = SlotKind.Order, table = "t" } },
        body = List#{
            Segment.Text("SELECT "), Segment.ParamRef("a"), Segment.Text(", "), Segment.ParamRef("b"), Segment.Text(", "), Segment.ParamRef("a"),
            Segment.Text("  "), Segment.SlotRef("filter"), Segment.Text(" "), Segment.SlotRef("order")
        }
    };
    Assert.assertEq(expected = ("SELECT $1, $2, $1  TRUE ", List#{"a", "b"}), QRender.toSql(queryDef))

/// パーサと繋いで、design.md §3 の searchUsers が EXPLAIN に貼れる形になる。
@Test
def testParseThenRender(): Unit \ Assert =
    let rendered = QParser.parseFile(
            "query searchUsers(limit: Int64) -> many with filter: Pred[users], order: Order[users] {\n"
                + "SELECT id FROM users WHERE deleted_at IS NULL AND {filter} {order} LIMIT :limit\n"
                + "}")
        |> Result.map(List.map(QRender.toSql));
    Assert.assertEq(expected = Ok(List#{("SELECT id FROM users WHERE deleted_at IS NULL AND TRUE  LIMIT $1", List#{"limit"})}), rendered)
