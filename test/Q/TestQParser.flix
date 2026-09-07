use QueryDef.Shape
use SqlType.SqlType
use QueryDef.SlotKind
use QueryDef.Segment
use QParser.ParseError

// QParser: .q の外側の文法と、本文の :name / {slot} の切り出し。

/// design.md §3 の users.q そのまま。
def usersQ(): String =
    "// users.q\n"
        + "query findUser(id: Int64) -> one {\n"
        + "    SELECT id, name, role FROM users WHERE id = :id\n"
        + "}\n"
        + "\n"
        + "query searchUsers(limit: Int64) -> many\n"
        + "    with filter: Pred[users], order: Order[users]\n"
        + "{\n"
        + "    SELECT id, name FROM users\n"
        + "    WHERE deleted_at IS NULL AND {filter}\n"
        + "    {order}\n"
        + "    LIMIT :limit\n"
        + "}\n"
        + "\n"
        + "query postsByUsers(ids: List[Int64]) -> many keyed(user_id) {\n"
        + "    SELECT id, user_id, title FROM posts WHERE user_id = ANY(:ids)\n"
        + "}\n"

/// 3 つの query の頭の部分（名前 / 引数 / 形 / keyed / slot）が読める。
@Test
def testParseHeaders(): Unit \ Assert =
    let headers = QParser.parseFile(usersQ())
        |> Result.map(List.map(queryDef -> (
            queryDef#name,
            List.map(param -> (param#name, param#paramType), queryDef#params),
            queryDef#shape,
            queryDef#keyed,
            List.map(slot -> (slot#name, slot#kind, slot#table), queryDef#slots)
        )));
    Assert.assertEq(expected = Ok(List#{
        ("findUser", List#{("id", SqlType.Int64)}, Shape.One, None, Nil),
        ("searchUsers", List#{("limit", SqlType.Int64)}, Shape.Many, None, List#{("filter", SlotKind.Pred, "users"), ("order", SlotKind.Order, "users")}),
        ("postsByUsers", List#{("ids", SqlType.Int64Array)}, Shape.Many, Some("user_id"), Nil)
    }), headers)

/// 本文は素の SQL / :name / {slot} に切れ、前後の空白は落ちる。
@Test
def testParseBodySegments(): Unit \ Assert =
    let bodies = QParser.parseFile(usersQ()) |> Result.map(List.map(queryDef -> queryDef#body));
    Assert.assertEq(expected = Ok(List#{
        List#{Segment.Text("SELECT id, name, role FROM users WHERE id = "), Segment.ParamRef("id")},
        List#{
            Segment.Text("SELECT id, name FROM users\n    WHERE deleted_at IS NULL AND "), Segment.SlotRef("filter"),
            Segment.Text("\n    "), Segment.SlotRef("order"),
            Segment.Text("\n    LIMIT "), Segment.ParamRef("limit")
        },
        List#{Segment.Text("SELECT id, user_id, title FROM posts WHERE user_id = ANY("), Segment.ParamRef("ids"), Segment.Text(")")}
    }), bodies)

/// 文字列リテラルの中の `:x` と `::text` のキャストは引数参照にならない。
@Test
def testBodyIgnoresQuotesAndCasts(): Unit \ Assert =
    let body = QParser.parseFile("query f(id: Int64) -> one { SELECT ':x', id::text FROM t WHERE id = :id }")
        |> Result.map(List.flatMap(queryDef -> queryDef#body));
    Assert.assertEq(expected = Ok(List#{Segment.Text("SELECT ':x', id::text FROM t WHERE id = "), Segment.ParamRef("id")}), body)

/// `Option[T]` の引数は中身の型と「NULL を渡せる」印になる。素の型は今までどおり optional = false。
///
///   role: Option[String] / expiresAt: Option[Timestamp] / id: Int64
@Test
def testParseOptionParams(): Unit \ Assert =
    let params = QParser.parseFile("query f(id: Int64, role: Option[String], expiresAt: Option[Timestamp]) -> exec "
            + "{ UPDATE t SET role = :role, expires_at = :expiresAt WHERE id = :id }")
        |> Result.map(List.flatMap(queryDef -> queryDef#params |> List.map(param -> (param#name, param#paramType, param#optional))));
    Assert.assertEq(expected = Ok(List#{
        ("id", SqlType.Int64, false),
        ("role", SqlType.Str, true),
        ("expiresAt", SqlType.Timestamp, true)
    }), params)

// ---- エラー ----

/// 宣言と使用の食い違いは最初の 1 つで止まる。
///
///   :nope が未宣言 / limit が未使用 / {f} が未宣言 / with の o が未使用 / keyed が one / 同名 2 つ
@Test
def testReferenceErrors(): Unit \ Assert =
    let errors = List#{
        "query a(id: Int64) -> one { SELECT :id, :nope }",
        "query a(id: Int64, limit: Int64) -> one { SELECT :id }",
        "query a() -> one { SELECT {f} }",
        "query a() -> one with o: Order[t] { SELECT 1 }",
        "query a() -> one keyed(x) { SELECT 1 }",
        "query a() -> one { SELECT 1 }\nquery a() -> one { SELECT 2 }"
    } |> List.map(source -> QParser.parseFile(source) |> Result.map(List.length));
    Assert.assertEq(expected = List#{
        Err(ParseError.UndeclaredParam("a", "nope")),
        Err(ParseError.UnusedParam("a", "limit")),
        Err(ParseError.UndeclaredSlot("a", "f")),
        Err(ParseError.UnusedSlot("a", "o")),
        Err(ParseError.KeyedRequiresMany("a")),
        Err(ParseError.DuplicateQuery("a"))
    }, errors)

/// 文法エラーは位置と期待した物を返す。
///
///   "query a(id: Nope) -> one {}"          → 12 文字目の型名が未知
///   "query a(id: Option[Nope]) -> one {}"  → Option の中身が未知（綴りは書いたまま）
///   "query a() -> one { SELECT 1"          → 閉じ括弧が無い（位置は末尾）
///   "quer a() -> one {}"                   → 先頭に query が無い
@Test
def testSyntaxErrors(): Unit \ Assert =
    let errors = List#{
        "query a(id: Nope) -> one {}",
        "query a(id: Option[Nope]) -> one {}",
        "query a() -> one { SELECT 1",
        "quer a() -> one {}"
    } |> List.map(source -> QParser.parseFile(source) |> Result.map(List.length));
    Assert.assertEq(expected = List#{
        Err(ParseError.UnknownType(12, "Nope")),
        Err(ParseError.UnknownType(12, "Option[Nope]")),
        Err(ParseError.Unexpected(27, "'}' closing the query body")),
        Err(ParseError.Unexpected(0, "'query'"))
    }, errors)

/// 本文の `--` コメントは落ちる。コメント中の `'` や `:x` は引数参照にならない。
@Test
def testBodyDropsLineComments(): Unit \ Assert =
    let body = QParser.parseFile("query f(id: Int64) -> one {\n  -- don't use :x here\n  SELECT id FROM t WHERE id = :id -- trailing\n}")
        |> Result.map(List.flatMap(queryDef -> queryDef#body));
    Assert.assertEq(expected = Ok(List#{Segment.Text("SELECT id FROM t WHERE id = "), Segment.ParamRef("id")}), body)
