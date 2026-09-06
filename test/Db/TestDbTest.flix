use SqlValue.SqlValue
use Row.Row
use DbError.DbFailure

// DbTest: テストハンドラと、Sql / DbError の使い心地。失敗は DbError.runWithFailure で 1 層の Result にして比べる。

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
    forA (
        id <- Decoder.int64("id");
        name <- Decoder.str("name")
    ) yield (id, name)

/// ユースケース関数の見本。読むだけ・DB エラーは上へ流す、がシグネチャに出る。
def findUserName(id: Int64): Option[String] \ DbRead + RawSql =
    Sql.fetchOneAs(Decoder.str("name"), "SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(id)})

// ---- runWithRows ----

/// runWithRows はどの SQL にも同じ行を返し、fetchAs でデコードできる。
@Test
def testRunWithRowsFetchAs(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok(List#{(1i64, "alice"), (2i64, "bob")}),
        RawSql.runWithAllow(() -> DbError.runWithFailure(() -> DbTest.runWithRows(dbTestUserRows(), () -> Sql.fetchAs(userDecoder(), "SELECT id, name FROM users", Nil)))))

/// fetchOne は先頭 1 行、0 行なら None。
@Test
def testFetchOne(): Unit \ Assert =
    let first = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> DbTest.runWithRows(dbTestUserRows(), () -> Sql.fetchOne("SELECT name FROM users", Nil) |> Option.flatMap(Row.get("name")))));
    let none = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> DbTest.runWithRows(Nil, () -> Sql.fetchOne("SELECT name FROM users", Nil) |> Option.flatMap(Row.get("name")))));
    Assert.assertEq(expected = (Ok(Some(SqlValue.Str("alice"))), Ok(None)), (first, none))

/// fetchAs はデコードに失敗したら DbErr.decodeError を投げる（静かな半壊にしない）。
@Test
def testFetchAsRaisesDbErrOnDecodeError(): Unit \ Assert =
    Assert.assertEq(
        expected = Err(DbFailure.Permanent("email: column 'email' is missing")),
        RawSql.runWithAllow(() -> DbError.runWithFailure(() -> DbTest.runWithRows(dbTestUserRows(), () -> Sql.fetchAs(Decoder.str("email"), "SELECT id, name FROM users", Nil)))))

/// runWithTable は SQL ごとに返す行を変えられる。知らない SQL は空。
@Test
def testRunWithTable(): Unit \ Assert =
    let rowsFor = sql -> if (sql == "SELECT id, name FROM users") Some(dbTestUserRows()) else None;
    let counts = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> DbTest.runWithTable(rowsFor, () -> (
        Sql.fetch("SELECT id, name FROM users", Nil) |> List.length,
        Sql.fetch("SELECT 1", Nil) |> List.length
    ))));
    Assert.assertEq(expected = Ok((2, 0)), counts)

// ---- ユースケース関数 ----

/// 見つかれば Some、見つからなければ None。DB エラーは runWithFailure で 1 層の Result になる。
@Test
def testFindUserName(): Unit \ Assert =
    let found = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> DbTest.runWithRows(dbTestUserRows(), () -> findUserName(1i64))));
    let missing = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> DbTest.runWithRows(Nil, () -> findUserName(9i64))));
    Assert.assertEq(expected = (Ok(Some("alice")), Ok(None)), (found, missing))

/// ハンドラが返した失敗は、呼び出し側の内側の runWithKind で拾える（アプリが制約違反を業務エラーに変える形）。
///
///   handler が Err(UniqueViolation) を返す → Sql.execute が op にする → 呼び出し側の runWithKind が受ける
@Test
def testFailureFromHandlerIsCatchableAtCallSite(): Unit \ Assert =
    let caught = run {
        RawSql.runWithAllow(() -> DbError.runWithKind(() -> Sql.execute("INSERT INTO users (name) VALUES ('a')", Nil)))
    } with handler SqlWrite {
        def execute(_sql, _params, resume) = resume(Err(DbError.DbErrorKind.UniqueViolation("users_name_key")))
        def executeReturning(_sql, _params, resume) = resume(Ok(Nil))
    };
    Assert.assertEq(expected = Err(DbError.DbErrorKind.UniqueViolation("users_name_key")), caught)

// ---- runRecording ----

/// runRecording は発行した文を順に記録する。
///
///   fetch  SELECT ...  $1 = 1
///   execute UPDATE ... $1 = "x", $2 = 1
@Test
def testRunRecordingStatements(): Unit \ Assert =
    let (affected, statements) = DbTest.runRecording(dbTestUserRows(), 1, () -> RawSql.runWithAllow(() -> DbError.runWithFailure(() -> {
        discard Sql.fetch("SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(1i64)});
        Sql.execute("UPDATE users SET name = $1 WHERE id = $2", List#{SqlValue.Str("x"), SqlValue.Int64(1i64)})
    })));
    Assert.assertEq(
        expected = (Ok(1), List#{
            ("SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(1i64)}),
            ("UPDATE users SET name = $1 WHERE id = $2", List#{SqlValue.Str("x"), SqlValue.Int64(1i64)})
        }),
        (affected, statements |> List.map(statement -> (statement#sql, statement#params))))

/// クエリ数のテストの形: ループで 5 回読めば発行数は 5。
@Test
def testRunRecordingQueryCount(): Unit \ Assert =
    let ids = List.range(0, 5) |> List.map(Int32.toInt64);
    let (_, statements) = DbTest.runRecording(dbTestUserRows(), 0, () -> RawSql.runWithAllow(() -> DbError.runWithFailure(() ->
        List.forEach(id -> discard Sql.fetch("SELECT name FROM users WHERE id = $1", List#{SqlValue.Int64(id)}), ids))));
    Assert.assertEq(expected = 5, List.length(statements))

// ---- runLogging（ハンドラの合成） ----

/// runLogging は Sql を包んで外側へ転送するので、内側の結果は変わらず、記録も外側に残る。
@Test
def testRunLoggingForwards(): Unit \ {Assert, IO} =
    let (rows, statements) = DbTest.runRecording(dbTestUserRows(), 0, () ->
        run {
            DbTest.runLogging(() -> RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Sql.fetch("SELECT id, name FROM users", Nil))))
        } with Logger.runWithIO);
    Assert.assertEq(expected = (Ok(2), 1), (Result.map(List.length, rows), List.length(statements)))

// ---- SELECT 句をデコーダから組む ----

/// selectClause を埋めた生 SQL は、デコーダが読む列だけを SELECT に出す。列名を書くのはデコーダの 1 回。
@Test
def testSelectClauseInRawSql(): Unit \ Assert =
    let (_, statements) = DbTest.runRecording(dbTestUserRows(), 0, () -> RawSql.runWithAllow(() -> DbError.runWithFailure(() ->
        Sql.fetchAs(userDecoder(), "SELECT ${Decoder.selectClause(userDecoder())} FROM users WHERE id = $1", List#{SqlValue.Int64(1i64)}))));
    Assert.assertEq(expected = List#{"SELECT id, name FROM users WHERE id = $1"}, List.map(statement -> statement#sql, statements))
