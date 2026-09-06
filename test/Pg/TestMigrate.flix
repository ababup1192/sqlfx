use SqlValue.SqlValue
use DbError.DbFailure
use Migrate.Status

// Migrate: 実 PG で apply / status / check。fixtures は test/fixtures/migrations（3 ファイル。003 は no-transaction）。

def fixtures(): String = "test/fixtures/migrations"

/// 記録テーブルと fixtures のテーブルを消す。毎回まっさらから。
def resetMigrations(): Unit \ IO =
    let cleared = withPg(() -> { let _ = Sql.execute("DROP TABLE IF EXISTS sqlfx_migrations, sqlfx_mig_test CASCADE", Nil); () });
    match cleared { case Ok(()) => () case Err(failure) => bug!("reset failed: ${failure}") }

def runMigrate(thunk: Unit -> a \ ef): Result[String, a] \ (ef - {Migrate.MigrateErr, TransientDbErr, DbErr, Fs.ReadFile.ReadFile, Fs.FileRead.FileRead, Fs.DirList.DirList}) + IO =
    let outcome = run {
        Migrate.runWithResult(() -> DbError.runWithFailure(thunk) |> Result.mapErr(failure -> "${failure}"))
    } with Fs.ReadFile.runWithFileRead
      with Fs.FileRead.runWithIO
      with Fs.DirList.runWithIO;
    Result.flatMap(identity, outcome)

/// apply は未適用を番号順に当て、2 回目は何も当てない。当てた後は status が全部 Applied で、check が通る。
///
///   001 create + insert / 002 add column / 003 index (no-transaction)
@Test
def testMigrateApplyThenNoop(): Unit \ {Assert, IO} =
    resetMigrations();
    let first = runMigrate(() -> Migrate.apply(Migrate.defaultConfig(pgConfig()), fixtures()));
    let second = runMigrate(() -> Migrate.apply(Migrate.defaultConfig(pgConfig()), fixtures()));
    let statuses = runMigrate(() -> Jdbc.withConnection(pgConfig(), conn -> Migrate.status(conn, fixtures())))
        |> Result.map(List.map(status -> match status { case Status.Applied(version, _, _) => (version, true) case Status.Pending(version) => (version, false) }));
    let checked = runMigrate(() -> Jdbc.withConnection(pgConfig(), conn -> Migrate.check(conn, fixtures())));
    let rows = withPg(() -> Sql.fetchAs(Decoder.opt(Decoder.str("note")), "SELECT note FROM sqlfx_mig_test", Nil));
    Assert.assertEq(
        expected = (Ok(List#{"001_create.sql", "002_add_note.sql", "003_index.sql"}), Ok(Nil),
                    Ok(List#{("001_create.sql", true), ("002_add_note.sql", true), ("003_index.sql", true)}), Ok(()), Ok(List#{None})),
        (first, second, statuses, checked, rows))

/// 当てる前の check は pending、適用済みの記録の checksum を書き換えると checksumMismatch、
/// ファイルに無い version を記録に足すと missingFile。どれも MigrateErr として型に出る。
@Test
def testMigrateCheckFailures(): Unit \ {Assert, IO} =
    resetMigrations();
    let pendingBefore = runMigrate(() -> Jdbc.withConnection(pgConfig(), conn -> Migrate.check(conn, fixtures())));
    let _ = runMigrate(() -> Migrate.apply(Migrate.defaultConfig(pgConfig()), fixtures()));
    let _ = withPg(() -> Sql.execute("UPDATE sqlfx_migrations SET checksum = 'tampered' WHERE version = '002_add_note.sql'", Nil));
    let mismatch = runMigrate(() -> Jdbc.withConnection(pgConfig(), conn -> Migrate.check(conn, fixtures())));
    let _ = withPg(() -> Sql.execute("UPDATE sqlfx_migrations SET checksum = $1 WHERE version = '002_add_note.sql'", List#{SqlValue.Str(Migrate.checksum("ALTER TABLE sqlfx_mig_test ADD COLUMN note TEXT;\n"))}));
    let _ = withPg(() -> Sql.execute("INSERT INTO sqlfx_migrations (version, checksum, execution_ms) VALUES ('000_gone.sql', 'x', 0)", Nil));
    let missing = runMigrate(() -> Jdbc.withConnection(pgConfig(), conn -> Migrate.check(conn, fixtures())));
    Assert.assertEq(
        expected = (Err("pending: 001_create.sql, 002_add_note.sql, 003_index.sql"), Err("checksum mismatch: 002_add_note.sql"), Err("missing file: 000_gone.sql")),
        (pendingBefore, mismatch, missing))

/// 形式の違うファイル名があれば、何も当てずに invalidFileName。
@Test
def testMigrateRejectsBadFileName(): Unit \ {Assert, IO} =
    resetMigrations();
    let result = runMigrate(() -> Migrate.apply(Migrate.defaultConfig(pgConfig()), "test/fixtures/bad_migrations"));
    Assert.assertEq(expected = Err("invalid file name: 1_short.sql (expected NNN_name.sql)"), result)

/// 途中のファイルが失敗すると、そのファイルは記録されず後続も当たらない。前のファイルは残る。
///
///   001 OK / 002 を壊す（存在しない表への ALTER）→ 002 と 003 は未適用のまま
@Test
def testMigrateStopsAtFirstFailure(): Unit \ {Assert, IO} =
    resetMigrations();
    let broken = "test/fixtures/broken_migrations";
    let outcome = runMigrate(() -> Migrate.apply(Migrate.defaultConfig(pgConfig()), broken))
        |> Result.mapErr(message -> String.startsWith(prefix = "Permanent(schemaMismatch", message));
    let statuses = runMigrate(() -> Jdbc.withConnection(pgConfig(), conn -> Migrate.status(conn, broken)))
        |> Result.map(List.map(status -> match status { case Status.Applied(version, _, _) => (version, true) case Status.Pending(version) => (version, false) }));
    Assert.assertEq(
        expected = (Err(true), Ok(List#{("001_create.sql", true), ("002_broken.sql", false), ("003_never.sql", false)})),
        (outcome, statuses))
