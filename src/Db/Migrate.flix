///
/// migrations/*.sql を DB に当てる。適用済みは `sqlfx_migrations` に記録し、前進のみ、1 ファイル 1 Tx、同時実行は advisory lock で 1 つ。
/// 生成器 `gen` と同じファイルを読むが、パーサは通さず JDBC の Statement にそのまま渡す（関数やトリガも当たる）。
///
/// WhyNot: `Sql.execute` を使わないのは、`$n` を `?` に書き換える経路なので `$$` の関数本体が壊れるから。
/// WhyNot: プールの接続で当てないのは、advisory lock が接続に紐づき、解放漏れの接続が戻ると次の migrate が永久に待つから。
///
mod Migrate {

    import java.sql.Connection
    import java.sql.Statement
    import java.sql.SQLException
    import java.security.MessageDigest
    import java.nio.charset.StandardCharsets
    import java.lang.System

    use SqlValue.SqlValue

    ///
    /// migrate 固有の失敗。SQL の失敗は DbErr のまま。
    ///
    pub eff MigrateErr {
        /// 適用済みのファイルが書き換わっている（version）
        def checksumMismatch(version: String): Void
        /// 記録にあるがディレクトリに無い（改名か削除）
        def missingFile(version: String): Void
        /// `NNN_name.sql` の形でない
        def invalidFileName(name: String): Void
        /// 同じ番号のファイルが 2 つ以上ある（ブランチのマージで起きる）
        def duplicateNumber(names: List[String]): Void
        /// check で未適用が残っている
        def pending(versions: List[String]): Void
    }

    ///
    /// 接続先と、DDL がロックを待つ上限。
    ///
    /// - `connection`: 専用の接続を 1 本開く先
    /// - `lockTimeoutMs`: `SET lock_timeout`。ALTER TABLE が長い SELECT の後ろで待ち続けて、他の全クエリを詰まらせないため
    ///
    pub type alias Config = { connection = Jdbc.ConnectionConfig, lockTimeoutMs = Int32 }

    ///
    /// 既定は lock_timeout 10 秒。
    ///
    pub def defaultConfig(connection: Jdbc.ConnectionConfig): Config =
        { connection = connection, lockTimeoutMs = 10000 }

    ///
    /// 1 ファイルの状態。`--status` の 1 行。
    ///
    pub enum Status with Eq, Order, ToString {
        /// (version, 適用時刻, かかった ms)
        case Applied(String, Timestamp.Timestamp, Int32)
        case Pending(String)
    }

    ///
    /// 読んだファイル。
    ///
    /// - `version`: ファイル名。記録テーブルのキー
    /// - `sql`: 全文
    /// - `checksum`: 正規化した全文の SHA-256（hex）
    /// - `noTransaction`: 先頭行が `-- sqlfx:no-transaction`
    ///
    type alias MigrationFile = { version = String, sql = String, checksum = String, noTransaction = Bool }

    ///
    /// 記録テーブルの 1 行。
    ///
    type alias Applied = { version = String, checksum = String, appliedAt = Timestamp.Timestamp, executionMs = Int32 }

    /// advisory lock のキー。固定値。
    def lockKey(): Int64 = 8151602112i64

    // ---- 入口 ----

    ///
    /// 未適用のファイルを番号順に当て、当てた version を返す。専用の接続を開き、lock を取り、必ず閉じる。
    /// 適用済みのファイルが書き換わっていれば何も当てずに checksumMismatch。
    ///
    pub def apply(config: Config, dir: String): List[String] \ {IO, Fs.ReadFile.ReadFile, Fs.DirList.DirList, TransientDbErr, DbErr, MigrateErr} =
        let files = loadFiles(dir);
        Jdbc.withConnection(config#connection, conn -> {
            executeRaw(conn, "SET lock_timeout = ${config#lockTimeoutMs}");
            executeRaw(conn, "SELECT pg_advisory_lock(${lockKey()})");
            let outcome = DbError.runWithKind(() -> {
                ensureTable(conn);
                let applied = readApplied(conn);
                verifyApplied(files, applied);
                pendingOf(files, applied) |> List.map(file -> { applyOne(conn, file); file#version })
            });
            executeRaw(conn, "SELECT pg_advisory_unlock(${lockKey()})");
            match outcome {
                case Ok(versions) => versions
                case Err(kind) => DbError.raise(kind)
            }
        })

    ///
    /// 全ファイルの状態。適用済みは記録の時刻と所要時間付き。ファイル名の順。
    ///
    pub def status(conn: Connection, dir: String): List[Status] \ {IO, Fs.ReadFile.ReadFile, Fs.DirList.DirList, TransientDbErr, DbErr, MigrateErr} =
        let files = loadFiles(dir);
        ensureTable(conn);
        let applied = readApplied(conn);
        List.map(file -> match List.find(row -> row#version == file#version, applied) {
            case Some(row) => Status.Applied(row#version, row#appliedAt, row#executionMs)
            case None => Status.Pending(file#version)
        }, files)

    ///
    /// 書かずに確かめる。未適用があれば pending、適用済みが書き換わっていれば checksumMismatch、記録にあるがファイルが無ければ missingFile。
    /// CI のデプロイ前と、アプリの起動時に呼ぶ。
    ///
    pub def check(conn: Connection, dir: String): Unit \ {IO, Fs.ReadFile.ReadFile, Fs.DirList.DirList, TransientDbErr, DbErr, MigrateErr} =
        let files = loadFiles(dir);
        ensureTable(conn);
        let applied = readApplied(conn);
        verifyApplied(files, applied);
        match pendingOf(files, applied) {
            case Nil => ()
            case waiting => MigrateErr.pending(List.map(file -> file#version, waiting))
        }

    ///
    /// MigrateErr を 1 層の Result に落とす。境界（main / テスト）で使う。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[String, a] \ ef - MigrateErr =
        run {
            Ok(thunk())
        } with handler MigrateErr {
            def checksumMismatch(version, _resume) = Err("checksum mismatch: ${version}")
            def missingFile(version, _resume) = Err("missing file: ${version}")
            def invalidFileName(name, _resume) = Err("invalid file name: ${name} (expected NNN_name.sql)")
            def duplicateNumber(names, _resume) = Err("duplicate number: ${List.join(", ", names)}")
            def pending(versions, _resume) = Err("pending: ${List.join(", ", versions)}")
        }

    // ---- ファイル ----

    ///
    /// ディレクトリ直下の .sql を名前順に読む。形式が違う名前が 1 つでもあれば invalidFileName、番号が重なれば duplicateNumber。
    ///
    def loadFiles(dir: String): List[MigrationFile] \ {IO, Fs.ReadFile.ReadFile, Fs.DirList.DirList, DbErr, MigrateErr} =
        let names = listSqlFiles(dir);
        List.forEach(name -> if (isValidFileName(name)) () else MigrateErr.invalidFileName(name), names);
        match duplicateNumbers(names) {
            case Nil => ()
            case duplicates :: _ => MigrateErr.duplicateNumber(duplicates)
        };
        List.map(name -> {
            let sql = match Fs.ReadFile.read("${dir}/${name}") {
                case Ok(text) => text
                case Err(e) => DbErr.other("cannot read ${dir}/${name}: ${e}")
            };
            { version = name, sql = sql, checksum = checksum(sql), noTransaction = hasNoTransactionMarker(sql) }
        }, names)

    ///
    /// ディレクトリ直下の .sql を名前順に。
    ///
    pub def listSqlFiles(dir: String): List[String] \ {Fs.DirList.DirList, DbErr} =
        match Fs.DirList.list(dir) {
            case Ok(entries) => entries |> List.filter(name -> String.endsWith(suffix = ".sql", name)) |> List.sort
            case Err(e) => DbErr.other("cannot list ${dir}: ${e}")
        }

    ///
    /// 同じ番号を持つファイル名の組。`001_a.sql` と `0001_b.sql` は同じ番号。形式が違う名前は見ない。重なりが無ければ Nil。
    ///
    pub def duplicateNumbers(names: List[String]): List[List[String]] =
        names
            |> List.filter(isValidFileName)
            |> List.groupBy(numberOf)
            |> List.map(Nel.toList)
            |> List.filter(group -> List.length(group) > 1)
            |> List.map(List.sort)
            |> List.sort

    ///
    /// 次のファイル名。今ある最大の番号 + 1 を 3 桁のゼロ埋めで付ける。空なら 001。
    ///
    pub def nextFileName(names: List[String], name: String): String =
        let next = names |> List.filterMap(numberOf) |> List.maximum |> Option.getWithDefault(0) |> (n -> n + 1);
        "${String.padLeft(3, '0', "${next}")}_${name}.sql"

    ///
    /// `migrate new` に渡す名前。小文字・数字・`_` だけで、先頭は小文字。
    ///
    pub def isValidMigrationName(name: String): Bool =
        String.forAll(c -> isLowerAscii(c) or Char.isDigit(c) or c == '_', name)
            and (String.toList(name) |> List.head |> Option.map(isLowerAscii) |> Option.getWithDefault(false))

    def isLowerAscii(c: Char): Bool = c >= 'a' and c <= 'z'

    ///
    /// 先頭の `NNN` を数として。形式が違えば None。
    ///
    def numberOf(name: String): Option[Int32] =
        if (isValidFileName(name))
            String.indexOf(substr = "_", name) |> Option.flatMap(underscore -> String.takeLeft(underscore, name) |> Int32.fromString)
        else None

    ///
    /// `NNN_name.sql`。番号は 3 桁以上のゼロ埋め。文字列順で並べても番号順になるように形を固定する。
    ///
    pub def isValidFileName(name: String): Bool =
        match String.indexOf(substr = "_", name) {
            case Some(underscore) =>
                let digits = String.takeLeft(underscore, name);
                let rest = String.dropLeft(underscore + 1, name);
                String.length(digits) >= 3 and String.forAll(Char.isDigit, digits) and String.endsWith(suffix = ".sql", rest) and String.length(rest) > 4
            case None => false
        }

    ///
    /// 先頭の空でない行が `-- sqlfx:no-transaction` か。
    ///
    pub def hasNoTransactionMarker(sql: String): Bool =
        String.splitOn(substr = "\n", sql)
            |> List.map(String.trim)
            |> List.find(line -> not String.isEmpty(line))
            |> Option.map(line -> line == "-- sqlfx:no-transaction")
            |> Option.getWithDefault(false)

    ///
    /// 正規化した全文の SHA-256。CRLF を LF に、各行末の空白と末尾の空行を落とす。コメントや空白の圧縮はしない（文字列リテラルを壊す）。
    ///
    pub def checksum(sql: String): String \ IO =
        let normalized = sql
            |> String.replace(src = "\r\n", dst = "\n")
            |> String.splitOn(substr = "\n")
            |> List.map(String.trimRight)
            |> List.reverse |> List.dropWhile(String.isEmpty) |> List.reverse
            |> List.join("\n");
        let bytes: Array[Int8, Static] = normalized.getBytes(StandardCharsets.UTF_8);
        let digest = MessageDigest.getInstance("SHA-256");
        let hashed: Array[Int8, Static] = digest.digest(bytes);
        Array.toList(hashed) |> List.map(hex) |> List.join("")

    def hex(byte: Int8): String =
        let value = Int8.toInt32(byte) |> Int32.bitwiseAnd(255);
        let digit = n -> String.charAt(n, "0123456789abcdef") |> Char.toString;
        digit(value / 16) + digit(Int32.bitwiseAnd(value, 15))

    // ---- 記録 ----

    def ensureTable(conn: Connection): Unit \ {IO, TransientDbErr, DbErr} =
        executeRaw(conn, "CREATE TABLE IF NOT EXISTS sqlfx_migrations (version TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now(), execution_ms INTEGER NOT NULL, applied_by TEXT NOT NULL DEFAULT current_user)")

    def readApplied(conn: Connection): List[Applied] \ {IO, TransientDbErr, DbErr} =
        let decoder = forA (
            version <- Decoder.str("version");
            sum <- Decoder.str("checksum");
            appliedAt <- Decoder.timestamp("applied_at");
            executionMs <- Decoder.int32("execution_ms")
        ) yield { version = version, checksum = sum, appliedAt = appliedAt, executionMs = executionMs };
        let rows = Jdbc.fetchRows(conn, "SELECT version, checksum, applied_at, execution_ms FROM sqlfx_migrations ORDER BY version", Nil);
        match Decoder.decodeRows(decoder, rows) {
            case Ok(applied) => applied
            case Err(error) => DbErr.decodeError(Decoder.errorColumn(error), Decoder.describeError(error))
        }

    ///
    /// 適用済みの記録とファイルを突き合わせる。記録にあるがファイルが無ければ missingFile、checksum が違えば checksumMismatch。
    ///
    def verifyApplied(files: List[MigrationFile], applied: List[Applied]): Unit \ MigrateErr =
        List.forEach(row -> match List.find(file -> file#version == row#version, files) {
            case None => MigrateErr.missingFile(row#version)
            case Some(file) => if (file#checksum == row#checksum) () else MigrateErr.checksumMismatch(row#version)
        }, applied)

    ///
    /// 記録に無いファイル。番号が適用済みより小さくても当てる（ブランチのマージで後から割り込む）。
    ///
    def pendingOf(files: List[MigrationFile], applied: List[Applied]): List[MigrationFile] =
        List.filter(file -> not List.exists(row -> row#version == file#version, applied), files)

    ///
    /// 1 ファイルを当てて記録する。Tx ありなら全文と記録の INSERT を同じ Tx に入れる。
    ///
    def applyOne(conn: Connection, file: MigrationFile): Unit \ {IO, TransientDbErr, DbErr} =
        let started = System.currentTimeMillis();
        let record = () -> {
            let elapsed = Int64.clampToInt32(min = 0, max = Int32.maxValue(), System.currentTimeMillis() - started);
            discard Jdbc.executeStatement(conn, "INSERT INTO sqlfx_migrations (version, checksum, execution_ms) VALUES ($1, $2, $3)",
                List#{SqlValue.Str(file#version), SqlValue.Str(file#checksum), SqlValue.Int32(elapsed)})
        };
        if (file#noTransaction) {
            executeRaw(conn, file#sql);
            record()
        } else
            Tx.withTx(conn, () -> { executeRaw(conn, file#sql); record() })

    ///
    /// 生 SQL を JDBC の Statement にそのまま渡す。複数文でも可（pgjdbc が `;` で分ける）。
    ///
    def executeRaw(conn: Connection, sql: String): Unit \ {IO, TransientDbErr, DbErr} =
        try {
            let statement: Statement = conn.createStatement();
            discard statement.execute(sql);
            statement.close()
        } catch {
            case e: SQLException => Jdbc.raiseSqlException(e)
        }

}
