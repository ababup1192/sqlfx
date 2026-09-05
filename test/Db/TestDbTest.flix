use SqlValue.SqlValue
use Row.Row

// DbTest: テストハンドラ 3 種と、Sql / DbError の使い心地。

/// users テーブルの結果セット。
///
///   id | name
///    1 | alice
///    2 | bob
def dbTestUserRows(): List[Row] =
    Row.makeRows(
        List#{"id", "name"},
        List#{
            List#{SqlValue.Int64(1i64), SqlValue.Str("alice")},
            List#{SqlValue.Int64(2i64), SqlValue.Str("bob")}
        })

/// id と name を組にするデコーダ。
def userDecoder(): Decoder.Decoder[(Int64, String)] =
    Decoder.pure(id -> name -> (id, name))
        |> Decoder.ap(Decoder.int64("id"))
        |> Decoder.ap(Decoder.str("name"))

/// ユースケース関数の見本。読むだけ・DB エラーは上へ流す、がシグネチャに出る。
def findUserName(id: Int64): Option[String] \ {SqlRead, DbErr} =
    Sql.fetchOneAs(Decoder.str("name"), "SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(id)})

// ---- runWithRows ----

/// runWithRows はどの SQL にも同じ行を返し、fetchAs でデコードできる。
@Test
def testRunWithRowsFetchAs(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok(List#{(1i64, "alice"), (2i64, "bob")}),
        DbError.runWithFailure(() -> DbTest.runWithRows(dbTestUserRows(), () -> Sql.fetchAs(userDecoder(), "SELECT id, name FROM users", Nil))))

/// fetchOne は先頭 1 行、0 行なら None。
@Test
def testFetchOne(): Unit \ Assert =
    Assert.assertEq(
        expected = (Some(SqlValue.Str("alice")), None),
        (
            DbTest.runWithRows(dbTestUserRows(), () -> Sql.fetchOne("SELECT name FROM users", Nil))
                |> Option.flatMap(Row.get("name")),
            DbTest.runWithRows(Nil, () -> Sql.fetchOne("SELECT name FROM users", Nil))
                |> Option.flatMap(Row.get("name"))
        ))

/// fetchAs はデコードに失敗したら DbErr.decodeError を投げる（静かな半壊にしない）。
@Test
def testFetchAsRaisesDbErrOnDecodeError(): Unit \ Assert =
    Assert.assertEq(
        expected = Err(DbError.DbFailure.Permanent("email: column 'email' is missing")),
        DbError.runWithFailure(() -> DbTest.runWithRows(dbTestUserRows(), () -> Sql.fetchAs(Decoder.str("email"), "SELECT id, name FROM users", Nil))))

/// runWithTable は SQL ごとに返す行を変えられる。知らない SQL は空。
@Test
def testRunWithTable(): Unit \ Assert =
    let table = sql -> if (sql == "SELECT id, name FROM users") Some(dbTestUserRows()) else None;
    Assert.assertEq(
        expected = (2, 0),
        (
            DbTest.runWithTable(table, () -> SqlRead.fetch("SELECT id, name FROM users", Nil)) |> List.length,
            DbTest.runWithTable(table, () -> SqlRead.fetch("SELECT 1", Nil)) |> List.length
        ))

// ---- ユースケース関数 ----

/// 見つかれば Some、見つからなければ None。DB エラーは runWithFailure で 1 層の Result になる。
@Test
def testFindUserName(): Unit \ Assert =
    let found = DbError.runWithFailure(() -> DbTest.runWithRows(dbTestUserRows(), () -> findUserName(1i64)));
    let missing = DbError.runWithFailure(() -> DbTest.runWithRows(Nil, () -> findUserName(9i64)));
    Assert.assertEq(expected = (Ok(Some("alice")), Ok(None)), (found, missing))

// ---- runRecording ----

/// runRecording は発行した文を順に記録する。N+1 の回帰は件数の上限で表明する。
///
///   fetch  SELECT ...  $1 = 1
///   execute UPDATE ... $1 = "x", $2 = 1
@Test
def testRunRecordingStatements(): Unit \ Assert =
    let (affected, statements) = DbTest.runRecording(dbTestUserRows(), 1, () -> {
        let _ = SqlRead.fetch("SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(1i64)});
        SqlWrite.execute("UPDATE users SET name = $1 WHERE id = $2", List#{SqlValue.Str("x"), SqlValue.Int64(1i64)})
    });
    Assert.assertEq(
        expected = (1, List#{
            ("SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(1i64)}),
            ("UPDATE users SET name = $1 WHERE id = $2", List#{SqlValue.Str("x"), SqlValue.Int64(1i64)})
        }),
        (affected, statements |> List.map(statement -> (statement#sql, statement#params))))

/// クエリ数の上限テストの形: ループで N 回読んでも発行数は N 以下。
@Test
def testRunRecordingQueryCountUpperBound(): Unit \ Assert =
    let ids = List.range(0, 5) |> List.map(Int32.toInt64);
    let (_, statements) = DbTest.runRecording(dbTestUserRows(), 0, () ->
        List.forEach(id -> {
            let _ = SqlRead.fetch("SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(id)});
            ()
        }, ids));
    Assert.assertTrue(List.length(statements) <= 5)

// ---- runLogging（ハンドラの合成） ----

/// runLogging は Sql を包んで外側へ転送するので、内側の結果は変わらず、記録も外側に残る。
@Test
def testRunLoggingForwards(): Unit \ {Assert, IO} =
    let (rows, statements) = DbTest.runRecording(dbTestUserRows(), 0, () ->
        run {
            DbTest.runLogging(() -> SqlRead.fetch("SELECT id, name FROM users", Nil))
        } with Logger.runWithIO);
    Assert.assertEq(expected = (2, 1), (List.length(rows), List.length(statements)))
