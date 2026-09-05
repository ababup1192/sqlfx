use SqlValue.SqlValue
use DbError.DbFailure

// Jdbc: 実 PostgreSQL に当たる層 5 のテスト。test/ の外に置き、make test-pg がコンテナを立てて test/Pg/ へ写して回す。

/// 環境変数から接続設定を組む。FLIX_DB_TEST_DSN が無ければ即 panic（黙って成功させない）。
def pgConfig(): Jdbc.ConnectionConfig \ IO =
    run {
        match Sys.Env.getVar("FLIX_DB_TEST_DSN") {
            case Some(url) => {
                url = url,
                user = Sys.Env.getVar("FLIX_DB_TEST_USER") |> Option.getWithDefault("flix"),
                password = Sys.Env.getVar("FLIX_DB_TEST_PASSWORD") |> Option.getWithDefault("flix")
            }
            case None => bug!("FLIX_DB_TEST_DSN が無い。make test-pg で回す")
        }
    } with Sys.Env.runWithIO

/// 接続を開いて body を走らせ、閉じる。失敗は DbFailure に落とす。
def withPg(body: Unit -> a \ {SqlRead, SqlWrite, TransientDbErr, DbErr, IO}): Result[DbFailure, a] \ IO =
    DbError.runWithFailure(() -> {
        let conn = Jdbc.connect(pgConfig());
        let result = Jdbc.runWithConnection(conn, body);
        Jdbc.close(conn);
        result
    })

/// テーブルを作り直す。
def resetUsers(): Unit \ SqlWrite =
    let _ = SqlWrite.execute("DROP TABLE IF EXISTS flix_db_test_users", Nil);
    let _ = SqlWrite.execute(
        "CREATE TABLE flix_db_test_users (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, "
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
        let _ = SqlWrite.execute(
            "INSERT INTO flix_db_test_users (name, email, score, active, created_at, born, tags, meta, uid) "
                + "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)", inserted);
        Sql.fetchOne("SELECT name, email, score, active, created_at, born, tags, meta, uid FROM flix_db_test_users", Nil)
            |> Option.map(row -> Row.columnNames(row) |> List.filterMap(name -> Row.get(name, row)))
    });
    Assert.assertEq(expected = Ok(Some(inserted)), result)

/// BIGSERIAL は Int64、影響行数は execute の戻り、0 行は None。
@Test
def testPgIdAndAffected(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        resetUsers();
        let inserted = SqlWrite.execute("INSERT INTO flix_db_test_users (name, created_at) VALUES ($1, now()), ($2, now())", List#{SqlValue.Str("a"), SqlValue.Str("b")});
        let ids = Sql.fetchAs(Decoder.int64("id"), "SELECT id FROM flix_db_test_users ORDER BY id", Nil);
        let missing = Sql.fetchOne("SELECT id FROM flix_db_test_users WHERE id = $1", List#{SqlValue.Int64(999i64)});
        (inserted, ids, Option.isEmpty(missing))
    });
    Assert.assertEq(expected = Ok((2, List#{1i64, 2i64}, true)), result)

// ---- 例外の翻訳 ----

/// unique 違反は DbErr.uniqueViolation に制約名付きで翻訳される。
@Test
def testPgUniqueViolation(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        resetUsers();
        let _ = SqlWrite.execute("INSERT INTO flix_db_test_users (name, email, created_at) VALUES ('a', 'x@example.com', now())", Nil);
        let _ = SqlWrite.execute("INSERT INTO flix_db_test_users (name, email, created_at) VALUES ('b', 'x@example.com', now())", Nil);
        ()
    });
    Assert.assertEq(expected = Err(DbFailure.Permanent("uniqueViolation flix_db_test_users_email_key")), result)

/// 無いテーブルは DbErr.schemaMismatch。PG のメッセージ本文はロケール依存なので、種別の接頭辞だけ見る。
@Test
def testPgMissingTableIsSchemaMismatch(): Unit \ {Assert, IO} =
    let result = withPg(() -> SqlRead.fetch("SELECT 1 FROM flix_db_no_such_table", Nil) |> List.length)
        |> Result.mapErr(failure -> String.startsWith(prefix = "Permanent(schemaMismatch", "${failure}"));
    Assert.assertEq(expected = Err(true), result)

/// ExampleUsers のユースケースが、テーブル名を合わせれば実 PG でもそのまま動く形であることの確認。
@Test
def testPgListUsersShape(): Unit \ {Assert, IO} =
    let result = withPg(() -> {
        resetUsers();
        let _ = SqlWrite.execute("INSERT INTO flix_db_test_users (name, email, created_at) VALUES ('bob', NULL, now()), ('alice', 'a@example.com', now())", Nil);
        Sql.fetchAs(ExampleUsers.userDecoder(), "SELECT id, name, email FROM flix_db_test_users ORDER BY name", Nil)
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
    let result = DbError.runWithFailure(() -> {
        let conn = Jdbc.connect(pgConfig());
        let _ = Jdbc.runWithConnection(conn, resetUsers);
        let failed = DbError.runWithFailure(() -> Tx.withTx(conn, () -> {
            let _ = SqlWrite.execute("INSERT INTO flix_db_test_users (name, email, created_at) VALUES ('a', 'x@example.com', now())", Nil);
            let _ = SqlWrite.execute("INSERT INTO flix_db_test_users (name, email, created_at) VALUES ('b', 'x@example.com', now())", Nil);
            ()
        }));
        let remaining = Jdbc.runWithConnection(conn, () -> SqlRead.fetch("SELECT id FROM flix_db_test_users", Nil) |> List.length);
        Jdbc.close(conn);
        (failed, remaining)
    });
    Assert.assertEq(expected = Ok((Err(DbFailure.Permanent("uniqueViolation flix_db_test_users_email_key")), 0)), result)

/// withTx は正常なら COMMIT する: 別接続から行が見える。
@Test
def testPgTxCommits(): Unit \ {Assert, IO} =
    let result = DbError.runWithFailure(() -> {
        let config = pgConfig();
        let conn = Jdbc.connect(config);
        let _ = Jdbc.runWithConnection(conn, resetUsers);
        Tx.withTx(conn, () -> {
            let _ = SqlWrite.execute("INSERT INTO flix_db_test_users (name, created_at) VALUES ('a', now())", Nil);
            ()
        });
        Jdbc.close(conn);
        let other = Jdbc.connect(config);
        let seen = Jdbc.runWithConnection(other, () -> SqlRead.fetch("SELECT id FROM flix_db_test_users", Nil) |> List.length);
        Jdbc.close(other);
        seen
    });
    Assert.assertEq(expected = Ok(1), result)
