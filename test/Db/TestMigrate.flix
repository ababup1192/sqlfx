// Migrate: ファイル名の形式、no-transaction の印、checksum の正規化。DB は使わない。

/// ファイル名は NNN_name.sql。番号は 3 桁以上のゼロ埋め。
@Test
def testMigrationFileNames(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{true, true, false, false, false, false},
        List#{
            Migrate.isValidFileName("001_users.sql"),
            Migrate.isValidFileName("0042_add_note.sql"),
            Migrate.isValidFileName("1_users.sql"),
            Migrate.isValidFileName("001users.sql"),
            Migrate.isValidFileName("abc_users.sql"),
            Migrate.isValidFileName("001_.sql")
        })

/// no-transaction の印は先頭の空でない行だけ見る。
@Test
def testNoTransactionMarker(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{true, true, false, false},
        List#{
            Migrate.hasNoTransactionMarker("-- sqlfx:no-transaction\nCREATE INDEX CONCURRENTLY ..."),
            Migrate.hasNoTransactionMarker("\n\n  -- sqlfx:no-transaction  \nCREATE INDEX ..."),
            Migrate.hasNoTransactionMarker("CREATE INDEX ...\n-- sqlfx:no-transaction"),
            Migrate.hasNoTransactionMarker("-- users\nCREATE TABLE ...")
        })

/// checksum は CRLF、行末の空白、末尾の空行の違いを無視し、中身の違いは検出する。
@Test
def testChecksumNormalization(): Unit \ {Assert, IO} =
    let base = Migrate.checksum("CREATE TABLE t (\n    id BIGINT\n);\n");
    Assert.assertEq(
        expected = (true, true, false),
        (base == Migrate.checksum("CREATE TABLE t (\r\n    id BIGINT   \r\n);\r\n\r\n"),
         base == Migrate.checksum("CREATE TABLE t (\n    id BIGINT\n);"),
         base == Migrate.checksum("CREATE TABLE t (\n    id INT\n);\n")))
