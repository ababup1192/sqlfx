# examples/blog

flix_db のデモ。ブログ（users / posts）を題材に、`.q` から生成した関数と、生 SQL をインラインで書く 2 つの書き方を並べる。

```
migrations/     DDL。机上のスキーマの元になり、テストでは実 PG にそのまま流す
queries/*.q     クエリ定義。`make gen` で src/Gen/ に Flix を生成する
src/Gen/        生成物（UsersQueries / PostsQueries / Tables）。手で直さない
src/Blog.flix   生成した関数を組み合わせたユースケース（断片 DSL・preload・Tx）
src/BlogRaw.flix 同じユースケースを生 SQL + 手書きデコーダで書いた版
src/flix_db/    本体のコピー（`make vendor` が作る。git には入れない）
test/           DB 無しのテスト。TestGeneratedPure（生成版）と TestRawSqlPure（生 SQL 版）。生成物が最新かの検査は本体側（make gen-check）
test/Pg/        実 PG のテスト。TestQueriesPg（決まったデータに対する各クエリの結果）、TestGeneratedPg（ユースケース）、TestRawSqlPg（生 SQL 版）。`make test-unit` は build/unit/ に Pg 抜きの写しを作って回す
```

VSCode で触るときは `make vendor` してから `code examples/blog` で別ウィンドウとして開く。`.vscode/settings.json` がルートと同じ `--Xsubeffecting=lambdas` を LSP に渡す（無いと `Unused effect` などの偽のエラーが出る）。Flix 拡張はワークスペースの最初のフォルダの `src/` と `test/` しか LSP に渡さないので、ルートのウィンドウから開くと「Flix will only load source files from ...」と出てハイライトも診断も効かない。

前提はルートの README と同じ（JDK、Docker、`FLIX_JAR` か devbox の jar）。`make gen` は本体の `main` を使うので、本体を GitHub 依存に切り替えた後も生成器は本体側で動かす。

```bash
make vendor    # ../../src/Db と ../../src/Q を src/flix_db/ に写す（check / test の前に自動で走る）
make gen       # migrations と queries/*.q から src/Gen/ を作り直す
make check     # 型検査
make test-unit # DB 無しのテスト
make test-pg   # docker compose で PG を立て、実 PG のテストを回し、止める
make test      # test-unit → test-pg
```

本体を GitHub にリリースしたら、`flix.toml` の `[dependencies]` で指す形に切り替えて `make vendor` を外す。
