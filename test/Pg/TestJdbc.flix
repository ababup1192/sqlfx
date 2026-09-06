use SqlValue.SqlValue
use DbError.DbFailure

// Jdbc: 実 PostgreSQL に当たる層 5 のテスト。test/ の外に置き、make test-pg がコンテナを立てて test/Pg/ へ写して回す。

/// 環境変数から接続設定を組む。SQLFX_TEST_DSN が無ければ即 panic（黙って成功させない）。
def pgConfig(): Jdbc.ConnectionConfig \ IO =
    run {
        match Sys.Env.getVar("SQLFX_TEST_DSN") {
            case Some(url) => {
                url = url,
                user = Sys.Env.getVar("SQLFX_TEST_USER") |> Option.getWithDefault("flix"),
                password = Sys.Env.getVar("SQLFX_TEST_PASSWORD") |> Option.getWithDefault("flix")
            }
            case None => bug!("SQLFX_TEST_DSN が無い。make test-pg で回す")
        }
    } with Sys.Env.runWithIO

/// 接続を開いて body を走らせ、必ず閉じる。失敗は DbFailure に落とす。
def withPg(body: Unit -> a \ Db + IO + RawSql): Result[DbFailure, a] \ IO =
    DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(pgConfig(), _ -> body())))

/// テーブルを作り直す。
def resetUsers(): Unit \ DbWrite + RawSql =
    let _ = Sql.execute("DROP TABLE IF EXISTS sqlfx_test_users", Nil);
    let _ = Sql.execute(
        "CREATE TABLE sqlfx_test_users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, "
            + "score NUMERIC(10, 2), active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL, "
            + "born DATE, tags TEXT[], meta JSONB, uid UUID)", Nil);
    ()

// ---- INSERT → SELECT ----

/// 型ごとの往復: 入れた SqlValue が同じ SqlValue で返る。
///
///   id | name  | email | score | active | created_at             | born       | tags    | meta      | uid
///    1 | alice | NULL  | 12.50 | true   | 2024-01-02T03:04:05.678Z | 2000-02-29 | {a,b}   | {"k":1}   | 0000...
@Test
def testPgRoundTrip(): Unit \ {Assert, IO} =
    let createdAt = 1704164645678000i64;
    let uid = "123e4567-e89b-12d3-a456-426614174000";
    let inserted = List#{
        SqlValue.Str("alice"), SqlValue.Null, SqlValue.Decimal(12.5ff), SqlValue.Bool(true),
        SqlValue.Timestamp(createdAt), SqlValue.Date(11016), SqlValue.StrArray(List#{"a", "b"}),
        SqlValue.Json("{\"k\": 1}"), SqlValue.Uuid(uid)
    };
    let result = withPg(() -> {
        resetUsers();
        let _ = Sql.execute(
            "INSERT INTO sqlfx_test_users (name, email, score, active, created_at, born, tags, meta, uid) "
                + "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)", inserted);
        Sql.fetchOne("SELECT name, email, score, active, created_at, born, tags, meta, uid FROM sqlfx_test_users", Nil)
            |> Option.map(row -> Row.columnNames(row) |> List.filterMap(name -> Row.get(name, row)))
    });
    Assert.assertEq(expected = Ok(Some(inserted)), result)

/// BIGSERIAL は Int64、影響行数は execute の戻り、0 行は None。
@Test
def testPgIdAndAffected(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        resetUsers();
        let inserted = Sql.execute("INSERT INTO sqlfx_test_users (name, created_at) VALUES ($1, now()), ($2, now())", List#{SqlValue.Str("a"), SqlValue.Str("b")});
        let ids = Sql.fetchAs(Decoder.int64("id"), "SELECT id FROM sqlfx_test_users ORDER BY id", Nil);
        let missing = Sql.fetchOne("SELECT id FROM sqlfx_test_users WHERE id = $1", List#{SqlValue.Int64(999i64)});
        (inserted, ids, Option.isEmpty(missing))
    });
    Assert.assertEq(expected = Ok((2, List#{1i64, 2i64}, true)), result)

// ---- 例外の翻訳 ----

/// unique 違反は DbErr.uniqueViolation に制約名付きで翻訳される。
@Test
def testPgUniqueViolation(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        resetUsers();
        let _ = Sql.execute("INSERT INTO sqlfx_test_users (name, email, created_at) VALUES ('a', 'x@example.com', now())", Nil);
        let _ = Sql.execute("INSERT INTO sqlfx_test_users (name, email, created_at) VALUES ('b', 'x@example.com', now())", Nil);
        ()
    });
    Assert.assertEq(expected = Err(DbFailure.Permanent("uniqueViolation sqlfx_test_users_email_key")), result)

/// 無いテーブルは DbErr.schemaMismatch。PG のメッセージ本文はロケール依存なので、種別の接頭辞だけ見る。
@Test
def testPgMissingTableIsSchemaMismatch(): Unit \ {Assert, IO} =
    let result = withPg(() -> Sql.fetch("SELECT 1 FROM sqlfx_no_such_table", Nil) |> List.length)
        |> Result.mapErr(failure -> String.startsWith(prefix = "Permanent(schemaMismatch", "${failure}"));
    Assert.assertEq(expected = Err(true), result)

/// ExampleUsers のユースケースが、テーブル名を合わせれば実 PG でもそのまま動く形であることの確認。
@Test
def testPgListUsersShape(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        resetUsers();
        let _ = Sql.execute("INSERT INTO sqlfx_test_users (name, email, created_at) VALUES ('bob', NULL, now()), ('alice', 'a@example.com', now())", Nil);
        Sql.fetchAs(ExampleUsers.userDecoder(), "SELECT id, name, email FROM sqlfx_test_users ORDER BY name", Nil)
            |> List.map(user -> (user#name, user#email))
    });
    Assert.assertEq(expected = Ok(List#{("alice", Some("a@example.com")), ("bob", None)}), result)

// ---- withTx ----

/// withTx は DbErr で ROLLBACK する: unique 違反の前に入れた行が残らない。
///
///   BEGIN
///     INSERT a        ← これは ROLLBACK で消える
///     INSERT a (重複) ← uniqueViolation
///   ROLLBACK
@Test
def testPgTxRollsBackOnDbErr(): Unit \ {Assert, IO} =
    let result = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> {
        let conn = Jdbc.connect(pgConfig());
        let _ = Jdbc.runWithConnection(conn, resetUsers);
        let failed = DbError.runWithFailure(() -> Tx.withTx(conn, () -> {
            let _ = Sql.execute("INSERT INTO sqlfx_test_users (name, email, created_at) VALUES ('a', 'x@example.com', now())", Nil);
            let _ = Sql.execute("INSERT INTO sqlfx_test_users (name, email, created_at) VALUES ('b', 'x@example.com', now())", Nil);
            ()
        }));
        let remaining = Jdbc.runWithConnection(conn, () -> Sql.fetch("SELECT id FROM sqlfx_test_users", Nil) |> List.length);
        Jdbc.close(conn);
        (failed, remaining)
    }));
    Assert.assertEq(expected = Ok((Err(DbFailure.Permanent("uniqueViolation sqlfx_test_users_email_key")), 0)), result)

/// withTx は正常なら COMMIT する: 別接続から行が見える。
@Test
def testPgTxCommits(): Unit \ {Assert, IO} =
    let result = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> {
        let config = pgConfig();
        let conn = Jdbc.connect(config);
        let _ = Jdbc.runWithConnection(conn, resetUsers);
        Tx.withTx(conn, () -> {
            let _ = Sql.execute("INSERT INTO sqlfx_test_users (name, created_at) VALUES ('a', now())", Nil);
            ()
        });
        Jdbc.close(conn);
        let other = Jdbc.connect(config);
        let seen = Jdbc.runWithConnection(other, () -> Sql.fetch("SELECT id FROM sqlfx_test_users", Nil) |> List.length);
        Jdbc.close(other);
        seen
    }));
    Assert.assertEq(expected = Ok(1), result)

// ---- NULL と型の網羅 ----

/// 変換が要る型（decimal / timestamp / date / bytea / 配列 / uuid / jsonb / double）が全部 NULL の行を読める。
@Test
def testPgAllNullRow(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_nulls", Nil);
        discard Sql.execute("CREATE TABLE sqlfx_test_nulls (d NUMERIC, t TIMESTAMPTZ, dt DATE, b BYTEA, ia BIGINT[], sa TEXT[], u UUID, j JSONB, f DOUBLE PRECISION, i INTEGER)", Nil);
        discard Sql.execute("INSERT INTO sqlfx_test_nulls DEFAULT VALUES", Nil);
        Sql.fetchOne("SELECT * FROM sqlfx_test_nulls", Nil) |> Option.map(row -> row#cells |> Vector.toList)
    });
    Assert.assertEq(expected = Ok(Some(List.repeat(10, SqlValue.Null))), result)

/// 1970 年より前の秒未満付き時刻、bytea、double、integer、bigint[] の往復。
@Test
def testPgMoreTypesRoundTrip(): Unit \ {Assert, IO} =
    let inserted = List#{SqlValue.Timestamp(-1500000i64), SqlValue.Bytes(Vector#{1i8, -2i8}), SqlValue.Float64(1.5), SqlValue.Int32(7), SqlValue.Int64Array(List#{1i64, 2i64})};
    let result = withPg(() -> {
        discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_types", Nil);
        discard Sql.execute("CREATE TABLE sqlfx_test_types (t TIMESTAMPTZ, b BYTEA, f DOUBLE PRECISION, i INTEGER, ia BIGINT[])", Nil);
        discard Sql.execute("INSERT INTO sqlfx_test_types VALUES ($1, $2, $3, $4, $5)", inserted);
        Sql.fetchOne("SELECT t, b, f, i, ia FROM sqlfx_test_types", Nil) |> Option.map(row -> row#cells |> Vector.toList)
    });
    Assert.assertEq(expected = Ok(Some(inserted)), result)

/// 意味を持つ型を実 PG と往復する。書くときは SqlValue.ofTimestamp 等で包み、読むときは Decoder.timestamp 等で意味を持つ型に戻る。
///
///   TIMESTAMPTZ '2026-09-06T01:00:00Z' / DATE '2026-09-06' / UUID / JSONB '{"n": 1}' → 同じ値で返る
@Test
def testPgSemanticTypesRoundTrip(): Unit \ {Assert, IO} =
    let at = Timestamp.at("2026-09-06T01:00:00.123456Z");
    let day = Date.at("2026-09-06");
    let key = Uuid.fromString("550e8400-e29b-41d4-a716-446655440000") |> Option.getWithDefault(Uuid.Uuid(""));
    let meta = Util.Json.Json.JObject(Map#{"n" => Util.Json.Json.JNumber(1ff)});
    let decoder = forA (
        t <- Decoder.timestamp("t");
        d <- Decoder.date("d");
        u <- Decoder.uuid("u");
        j <- Decoder.jsonAs("j")
    ) yield (t, d, u, (j: Map[String, Int32]));
    let result = withPg(() -> {
        discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_semantic", Nil);
        discard Sql.execute("CREATE TABLE sqlfx_test_semantic (t TIMESTAMPTZ, d DATE, u UUID, j JSONB)", Nil);
        discard Sql.execute("INSERT INTO sqlfx_test_semantic VALUES ($1, $2, $3, $4)", List#{SqlValue.ofTimestamp(at), SqlValue.ofDate(day), SqlValue.ofUuid(key), SqlValue.ofJson(meta)});
        Sql.fetchOneAs(decoder, "SELECT t, d, u, j FROM sqlfx_test_semantic", Nil)
    });
    Assert.assertEq(expected = Ok(Some((at, day, key, Map#{"n" => 1}))), result)

/// 実 PG でも Decoder の型不一致は DbErr.decodeError になる（BIGSERIAL を Int32 で読む）。
@Test
def testPgDecodeErrorIsDbErr(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        resetUsers();
        discard Sql.execute("INSERT INTO sqlfx_test_users (name, created_at) VALUES ('a', now())", Nil);
        Sql.fetchAs(Decoder.int32("id"), "SELECT id FROM sqlfx_test_users", Nil)
    });
    Assert.assertEq(expected = Err(DbFailure.Permanent("id: column 'id' is Int64, expected Int32")), result)

// ---- withConnection / COMMIT の失敗 ----

/// withConnection は失敗しても接続を閉じ、エラーはそのまま上がる。
@Test
def testPgWithConnectionClosesOnError(): Unit \ {Assert, IO} =
    let result = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Jdbc.withConnection(pgConfig(), _ -> Sql.fetch("SELECT 1 FROM sqlfx_no_such_table", Nil))))
        |> Result.mapErr(failure -> String.startsWith(prefix = "Permanent(schemaMismatch", "${failure}"))
        |> Result.map(List.length);
    Assert.assertEq(expected = Err(true), result)

/// COMMIT で初めて出るエラー（DEFERRABLE な unique）も DbErr に翻訳され、接続は autocommit に戻っている。
///
///   BEGIN → INSERT a → INSERT a（遅延 unique なのでここでは通る）→ COMMIT ← ここで 23505
///   その後の INSERT が普通に見える = autocommit に戻っている
@Test
def testPgCommitFailureIsTranslated(): Unit \ {Assert, IO} =
    let result = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Jdbc.withConnection(pgConfig(), conn -> {
        resetUsers();
        discard Sql.execute("ALTER TABLE sqlfx_test_users ADD CONSTRAINT sqlfx_test_users_name_deferred UNIQUE (name) DEFERRABLE INITIALLY DEFERRED", Nil);
        let failed = DbError.runWithFailure(() -> Tx.withTx(conn, () -> {
            discard Sql.execute("INSERT INTO sqlfx_test_users (name, created_at) VALUES ('dup', now())", Nil);
            discard Sql.execute("INSERT INTO sqlfx_test_users (name, created_at) VALUES ('dup', now())", Nil)
        }));
        discard Sql.execute("INSERT INTO sqlfx_test_users (name, created_at) VALUES ('after', now())", Nil);
        let seen = Jdbc.withConnection(pgConfig(), _ -> Sql.fetch("SELECT id FROM sqlfx_test_users", Nil) |> List.length);
        (failed, seen)
    })));
    Assert.assertEq(expected = Ok((Err(DbFailure.Permanent("uniqueViolation sqlfx_test_users_name_deferred")), 1)), result)
