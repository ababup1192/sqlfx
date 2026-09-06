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

/// 同じ番号のファイルを組にして返す。桁数が違っても同じ番号。形式が違う名前は組にしない。
@Test
def testDuplicateNumbers(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{List#{"001_users.sql", "0001_posts.sql"} |> List.sort, List#{"003_a.sql", "003_b.sql"}},
        Migrate.duplicateNumbers(List#{"001_users.sql", "002_tags.sql", "0001_posts.sql", "003_b.sql", "003_a.sql", "bad.sql", "bad2.sql"}))

/// 重なりが無ければ Nil。
@Test
def testDuplicateNumbersNone(): Unit \ Assert =
    Assert.assertEq(expected = Nil, Migrate.duplicateNumbers(List#{"001_users.sql", "002_tags.sql"}))

/// `migrate new` の名前は今ある最大の番号 + 1。空なら 001。4 桁があればその次。
@Test
def testNextFileName(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{"001_users.sql", "003_tags.sql", "1001_tags.sql"},
        List#{
            Migrate.nextFileName(Nil, "users"),
            Migrate.nextFileName(List#{"002_posts.sql", "001_users.sql"}, "tags"),
            Migrate.nextFileName(List#{"1000_posts.sql"}, "tags")
        })

/// `migrate new` に渡す名前は小文字・数字・`_` だけ。先頭は小文字。
@Test
def testMigrationNames(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{true, true, false, false, false, false},
        List#{
            Migrate.isValidMigrationName("add_note"),
            Migrate.isValidMigrationName("v2_posts"),
            Migrate.isValidMigrationName("AddNote"),
            Migrate.isValidMigrationName("add-note"),
            Migrate.isValidMigrationName("2_posts"),
            Migrate.isValidMigrationName("")
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
