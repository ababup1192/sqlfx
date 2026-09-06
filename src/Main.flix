///
/// `bin/flix run -- gen <migrations/> <queries/> <out/>`: migrations でスキーマを組み、queries の .q から Flix を生成する。
/// `gen --check ...` は書かずに、生成物が最新かだけを確かめる（CI 用。古ければ終了コード 1）。
/// 生成器を別プロジェクトにしないのは、flix.toml にローカルパス依存が無いから（PLAN フェーズ 2-3）。
///
def main(): Unit \ {IO, Sys.Env.Env, Sys.Exit.Exit, Fs.DirList.DirList, Fs.FileRead.FileRead, Fs.FileWrite.FileWrite} =
    run {
        match Sys.Env.getArgs() {
            case "gen" :: migrationsDir :: queriesDir :: outDir :: Nil => Gen.generateAll({ migrations = migrationsDir, queries = queriesDir, out = outDir })
            case "gen" :: "--check" :: migrationsDir :: queriesDir :: outDir :: Nil => Gen.checkAll({ migrations = migrationsDir, queries = queriesDir, out = outDir })
            case _ => {
                println("usage: bin/flix run -- gen [--check] <migrations dir> <queries dir> <out dir>");
                Sys.Exit.exit(2)
            }
        }
    } with Fs.ReadFile.runWithFileRead
      with Fs.WriteFile.runWithFileWrite
      with Fs.MkDirs.runWithFileWrite

mod Gen {

    ///
    /// 生成の入出力。3 つともディレクトリのパスなので、並べずに名前で持つ。
    ///
    /// - `migrations`: DDL の場所
    /// - `queries`: .q の場所
    /// - `out`: 生成物を書く場所
    ///
    pub type alias Dirs = { migrations = String, queries = String, out = String }

    ///
    /// 生成の本体。失敗は 1 つ目を表示して終了コード 1。
    ///
    pub def generateAll(dirs: Dirs): Unit \ {IO, Sys.Exit.Exit, Fs.ReadFile.ReadFile, Fs.WriteFile.WriteFile, Fs.DirList.DirList, Fs.MkDirs.MkDirs} =
        match generate(dirs) {
            case Ok(written) => List.forEach(path -> println("wrote ${path}"), written)
            case Err(message) => {
                println("error: ${message}");
                Sys.Exit.exit(1)
            }
        }

    ///
    /// 生成物が最新か。古い（無い・中身が違う）ファイルを表示して終了コード 1。
    ///
    pub def checkAll(dirs: Dirs): Unit \ {IO, Sys.Exit.Exit, Fs.ReadFile.ReadFile, Fs.DirList.DirList} =
        match staleFiles(dirs) {
            case Ok(Nil) => println("up to date")
            case Ok(stale) => {
                List.forEach(path -> println("stale: ${path}"), stale);
                Sys.Exit.exit(1)
            }
            case Err(message) => {
                println("error: ${message}");
                Sys.Exit.exit(1)
            }
        }

    ///
    /// 今の生成器で作った物と outDir の現物が違うファイル。全部一致なら Nil。テストと CI がこれを使う。
    ///
    pub def staleFiles(dirs: Dirs): Result[String, List[String]] \ {IO, Fs.ReadFile.ReadFile, Fs.DirList.DirList} =
        render(dirs)
            |> Result.map(files -> files |> List.filterMap(file -> {
                let (path, code) = file;
                if (Fs.ReadFile.read(path) == Ok(code)) None else Some(path)
            }))

    ///
    /// 書いたファイルの一覧を返す。
    ///
    def generate(dirs: Dirs): Result[String, List[String]] \ {IO, Fs.ReadFile.ReadFile, Fs.WriteFile.WriteFile, Fs.DirList.DirList, Fs.MkDirs.MkDirs} =
        forM (
            files <- render(dirs);
            _ <- Fs.MkDirs.mkDirs(dirs#out) |> Result.mapErr(e -> "cannot create ${dirs#out}: ${e}");
            written <- Result.traverse(file -> { let (path, code) = file; writeFile(path, code) }, files)
        ) yield written

    ///
    /// 出力先のパスと中身を全部作る。書かない。
    ///
    def render(dirs: Dirs): Result[String, List[(String, String)]] \ {IO, Fs.ReadFile.ReadFile, Fs.DirList.DirList} =
        forM (
            sqlFiles <- listFiles(dirs#migrations, ".sql");
            schema <- buildSchema(sqlFiles);
            qFiles <- listFiles(dirs#queries, ".q");
            queryFiles <- Result.traverse(path -> renderOne(schema, path, dirs#out), qFiles);
            tables <- Codegen.renderTables(schema) |> Result.mapErr(error -> "Tables.flix: ${error}")
        ) yield ("${dirs#out}/Tables.flix", tables) :: queryFiles

    ///
    /// migrations をファイル名順に適用する。読めない DDL は警告として表示する。
    ///
    def buildSchema(sqlFiles: List[String]): Result[String, Schema.Schema] \ {IO, Fs.ReadFile.ReadFile} =
        Result.foldLeftM((schema, path) ->
            forM (
                sql <- readFile(path);
                applied <- DdlParser.apply(sql, schema) |> Result.mapErr(e -> "${path}: ${e}")
            ) yield {
                let (next, warnings) = applied;
                List.forEach(warning -> println("warning: ${path}: ${warning}"), warnings);
                next
            }, Schema.empty(), sqlFiles)

    ///
    /// 1 つの .q → 1 つの .flix（出力先のパスと中身）。
    ///
    def renderOne(schema: Schema.Schema, path: String, outDir: String): Result[String, (String, String)] \ Fs.ReadFile.ReadFile =
        let fileName = String.splitOn(substr = "/", path) |> List.last |> Option.getWithDefault(path);
        forM (
            source <- readFile(path);
            queries <- QParser.parseFile(source) |> Result.mapErr(e -> "${path}: ${e}");
            resolved <- Result.traverse(QResolve.resolve(schema), queries) |> Result.mapErr(e -> "${path}: ${e}");
            code <- Codegen.renderQueries({ fileName = fileName, source = source }, resolved) |> Result.mapErr(e -> "${path}: ${e}")
        ) yield ("${outDir}/${Codegen.moduleNameOf(fileName)}.flix", code)

    ///
    /// ディレクトリ直下の、拡張子が合うファイルを名前順に。
    ///
    def listFiles(dir: String, extension: String): Result[String, List[String]] \ Fs.DirList.DirList =
        Fs.DirList.list(dir)
            |> Result.mapErr(e -> "cannot list ${dir}: ${e}")
            |> Result.map(entries -> entries |> List.filter(name -> String.endsWith(suffix = extension, name)) |> List.sort |> List.map(name -> "${dir}/${name}"))

    def readFile(path: String): Result[String, String] \ Fs.ReadFile.ReadFile =
        Fs.ReadFile.read(path) |> Result.mapErr(e -> "cannot read ${path}: ${e}")

    def writeFile(path: String, content: String): Result[String, String] \ Fs.WriteFile.WriteFile =
        Fs.WriteFile.write(str = content, path) |> Result.mapErr(e -> "cannot write ${path}: ${e}") |> Result.map(_ -> path)

}
