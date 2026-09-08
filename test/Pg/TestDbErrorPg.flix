use SqlValue.SqlValue
use DbError.DbErrorKind
use DbError.Failure
use DbError.TransientKind

// DbErrorKind の分類を実 PG で起こす。SQLState → kind の翻訳表（SqlState.classifyWith）が DB 無しの表と、
// 実際にサーバが返す物で食い違わないかと、isTransient（再試行に乗るか）を見る。

/// kind を比べやすい形にする。制約名・列名はそのまま、メッセージを持つ物は種類（と SQLState）だけ。
def shapeOf(failure: Failure): String = match failure {
    case Failure.Transient(TransientKind.ConnectionLost(_)) => "transient connectionLost"
    case Failure.Transient(transient)                       => "transient ${DbError.describeTransient(transient)}"
    case Failure.Permanent(DbErrorKind.SchemaMismatch(_))   => "schemaMismatch"
    case Failure.Permanent(DbErrorKind.Other(detail))       => "other ${String.takeLeft(5, detail)}"
    case Failure.Permanent(kind)                            => DbError.describe(kind)
}

/// 分類用の表を作り直す。
def resetKindTables(): Unit \ DbWrite + RawSql =
    discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_kind_posts", Nil);
    discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_kinds", Nil);
    discard Sql.execute(
        "CREATE TABLE sqlfx_test_kinds (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, "
            + "CONSTRAINT sqlfx_test_kinds_name_len CHECK (length(name) >= 2))", Nil);
    discard Sql.execute("CREATE TABLE sqlfx_test_kind_posts (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL REFERENCES sqlfx_test_kinds (id))", Nil);
    discard Sql.execute("INSERT INTO sqlfx_test_kinds (name, email) VALUES ('alice', 'a@example.com')", Nil)

/// 新しい接続で body を走らせ、失敗の形を返す。
def failureOn(body: Unit -> Unit \ ef): Result[String, Unit] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql}) + IO =
    RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Jdbc.withConnection(pgConfig(), _ -> body()))) |> Result.mapErr(shapeOf)

/// 別の接続が行をロックしている間に、lock_timeout 付きで同じ行を取る。
def lockTimeoutCase(): Result[String, Unit] \ IO =
    RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Jdbc.withConnection(pgConfig(), holder ->
        Tx.withTx(holder, () -> {
            discard Sql.fetch("SELECT id FROM sqlfx_test_kinds WHERE name = 'alice' FOR UPDATE", Nil);
            failureOn(() -> {
                discard Sql.execute("SET lock_timeout = 100", Nil);
                discard Sql.fetch("SELECT id FROM sqlfx_test_kinds WHERE name = 'alice' FOR UPDATE", Nil)
            })
        }))))
        |> Result.mapErr(shapeOf)
        |> Result.flatMap(inner -> inner)

/// REPEATABLE READ の Tx で読んだ行を、別の接続が先に更新して COMMIT した後に更新する（40001）。
def serializationFailureCase(): Result[String, Unit] \ IO =
    RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Jdbc.withConnection(pgConfig(), reader ->
        Tx.withTx(reader, () -> {
            discard Sql.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", Nil);
            discard Sql.fetch("SELECT id FROM sqlfx_test_kinds WHERE name = 'alice'", Nil);
            discard failureOn(() -> discard Sql.execute("UPDATE sqlfx_test_kinds SET email = 'b@example.com' WHERE name = 'alice'", Nil));
            discard Sql.execute("UPDATE sqlfx_test_kinds SET email = 'c@example.com' WHERE name = 'alice'", Nil)
        }))))
        |> Result.mapErr(shapeOf)

/// 閉じた接続で SQL を出す（08003）。
def closedConnectionCase(): Result[String, Unit] \ IO =
    RawSql.runWithAllow(() -> DbError.runWithFailure(() -> {
        let conn = Jdbc.connect(pgConfig());
        Jdbc.close(conn);
        Jdbc.runWithConnection(conn, () -> discard Sql.fetch("SELECT 1", Nil))
    })) |> Result.mapErr(shapeOf)

/// 自分の backend をサーバ側から止める（57P01）。その次の SQL は接続が切れている（08006）。
def terminatedBackendCase(): (Result[String, Unit], Result[String, Unit]) \ IO =
    RawSql.runWithAllow(() -> match DbError.runWithFailure(() -> Jdbc.connect(pgConfig())) {
        case Err(failure) => bug!("接続できない: ${DbError.describeFailure(failure)}")
        case Ok(victim) => {
            let terminated = DbError.runWithFailure(() -> Jdbc.runWithConnection(victim, () -> discard Sql.fetch("SELECT pg_terminate_backend(pg_backend_pid())", Nil))) |> Result.mapErr(shapeOf);
            let afterwards = DbError.runWithFailure(() -> Jdbc.runWithConnection(victim, () -> discard Sql.fetch("SELECT 1", Nil))) |> Result.mapErr(shapeOf);
            Jdbc.close(victim);
            (terminated, afterwards)
        }
    })

/// サーバが返す SQLState ごとの kind。isTransient に乗る物（transient …）は再試行される。
///
///   unique 違反 23505                       → uniqueViolation sqlfx_test_kinds_email_key
///   外部キー違反 23503                       → foreignKeyViolation sqlfx_test_kind_posts_user_id_fkey
///   CHECK 違反 23514                         → checkViolation sqlfx_test_kinds_name_len
///   NOT NULL 違反 23502                      → notNullViolation name
///   statement_timeout 57014                 → transient timeout 0
///   lock_timeout 55P03                      → transient timeout 0（ロック待ちの上限。再試行で通りうる）
///   直列化失敗 40001                         → transient deadlock
///   表が無い 42P01                           → schemaMismatch
///   0 除算 22012                             → other 22012
///   閉じた接続 08003                         → transient connectionLost
///   pg_terminate_backend 57P01              → transient connectionLost（DB の再起動で出る物。再試行で跨ぐ）
///   その後の SQL 08006                       → transient connectionLost
@Test
def testPgErrorKindTable(): Unit \ {Assert, IO} =
    discard failureOn(resetKindTables);
    let (terminated, afterTerminate) = terminatedBackendCase();
    let seen = List#{
        failureOn(() -> discard Sql.execute("INSERT INTO sqlfx_test_kinds (name, email) VALUES ('bob', 'a@example.com')", Nil)),
        failureOn(() -> discard Sql.execute("INSERT INTO sqlfx_test_kind_posts (user_id) VALUES (999999)", Nil)),
        failureOn(() -> discard Sql.execute("INSERT INTO sqlfx_test_kinds (name) VALUES ('x')", Nil)),
        failureOn(() -> discard Sql.execute("INSERT INTO sqlfx_test_kinds (name) VALUES (NULL)", Nil)),
        failureOn(() -> { discard Sql.execute("SET statement_timeout = 50", Nil); discard Sql.fetch("SELECT pg_sleep(1)", Nil) }),
        lockTimeoutCase(),
        serializationFailureCase(),
        failureOn(() -> discard Sql.fetch("SELECT * FROM sqlfx_no_such_table", Nil)),
        failureOn(() -> discard Sql.fetch("SELECT 1 / 0", Nil)),
        closedConnectionCase(),
        terminated,
        afterTerminate
    };
    Assert.assertEq(
        expected = List#{
            Err("uniqueViolation sqlfx_test_kinds_email_key"),
            Err("foreignKeyViolation sqlfx_test_kind_posts_user_id_fkey"),
            Err("checkViolation sqlfx_test_kinds_name_len"),
            Err("notNullViolation name"),
            Err("transient timeout 0"),
            Err("transient timeout 0"),
            Err("transient deadlock"),
            Err("schemaMismatch"),
            Err("other 22012"),
            Err("transient connectionLost"),
            Err("transient connectionLost"),
            Err("transient connectionLost")
        },
        seen)
