# sqlfx 実装プラン

設計の正は [docs/design.md](docs/design.md)、層0 の API は [docs/layer0.md](docs/layer0.md)。
このファイルはそれを「どの順で・何を確かめながら作るか」に落とした物。
設計の §番号はそのまま参照する。各フェーズは「テストが通る状態」で区切り、1 フェーズ 1 PR を目安にする。

## 方針

- **層0 だけで思想の核が全部動く**（§10）。層0 を最優先で完成させ、それ以降は層0 の上に積む
- Flix のお約束（`AGENTS.md`・`docs/flix-conventions.md`）を守る。`query` / `select` / `where` / `run` は
  予約語なので識別子に使わない（`.q` の `query` はファイル側の文法であって Flix の識別子ではない）
- `\ SqlRead / SqlWrite` を持つ関数は薄く、ロジックは純粋関数へ（§9）。テストは DB 無しの層 1〜3 を厚くする
- 実 PostgreSQL が要るテスト（層 5）は最後まで少数に留める。`bin/flix test` は `test/` の `@Test` を
  全部走らせ、絞り込みが無いので、`make test-unit` は build/unit/ に `test/Pg/` 抜きの写しを作って回し、`make test-pg` はコンテナを立てて全部回す。
  `test/Pg/` を test/ の外に置かないのは、VSCode の Flix 拡張が src/ と test/ しか LSP に渡さないため。DSN が無ければ `bug!` で即落とす（黙って成功させない）

## フェーズ 0: 土台（今ここ）

- [x] hello world・`bin/flix`・skills・conventions のコピー
- [x] JDBC 依存を `flix.toml` に足す（`org.postgresql:postgresql`）
- [x] 層0 の API 設計（`docs/layer0.md`）
- [x] 技術リスクのスパイク（§10）。結果は [docs/spikes.md](docs/spikes.md)（スパイクのファイル自体は消した）
  - (a) エフェクト集合を `type alias` にできるか → できる。`Db` alias 採用
  - (b) `spawn` 本体に自作エフェクト（`SqlRead`）を置けるか → 置けない。Tx 内並行は言語側で禁止済み
  - (c) Maven 依存の `org.postgresql.Driver` を直接ロードして接続できるか → `new Driver().connect` で通る
    （`DriverManager` は経由しない）

## フェーズ 1: 層0 = v0（§4, §7, layer0.md）

生SQL を型付きで実行できる。ここまでで「エフェクト境界・エラー3分類・ハンドラ差し替え」が全部動く。
型と関数名は `docs/layer0.md` が正。順番だけここに書く。

1. [x] **値の型** `src/Db/`: `SqlValue` → `Row` / `ColumnIndex` → `Decoder`。全部純粋。層 1 のテスト
2. [x] **エフェクト** `Sql.flix` / `DbError.flix`: `SqlRead.fetch` / `SqlWrite.execute` / エラー 2 分類（全 op Void）+ `runWithFailure`
3. [x] **テストハンドラ 3 種** `src/Db/Test/DbTest.flix` — JDBC より先に作る。ここで API の使い心地を確かめる
   - `runWithRows`（固定 `Row` を返す）
   - `runRecording`（発行 SQL とパラメータを記録。§9 層3 の `assertLe` 用）
   - `runLogging`（`Sql` を包む中間ハンドラ。合成できることの確認）
4. [x] **サンプルのユースケース** `test/Example/ExampleUsers.flix`: `findUser` / `listUsers` / `renameUser`。
   本体は純粋なライブラリなので test 側に置く。`runWithRows` / `runRecording` でテスト済み
5. [x] **JDBC ハンドラ** `src/Db/Jdbc/`
   - [x] `SqlState.classify`（sqlstate → `DbErrorKind`）は純粋関数。翻訳表を先にテスト
   - [x] `SqlValue` ⇔ JDBC の変換 `JdbcConvert`（`wasNull` / DECIMAL は `BigDecimal` / TIMESTAMPTZ は `OffsetDateTime` / uuid・json・配列）
   - [x] `ResultSet` の即時 materialize
   - [x] 継続は必ず 1 回だけ呼ぶ規約（`Jdbc.runWithConnection`）
   - [x] 失敗時も `PreparedStatement` を閉じる
6. [x] **`withRetry`**: Transient を捕まえて thunk を呼び直す。枯渇で `DbErr.retryExhausted`。層 2 のテスト
7. [x] **`withTx` の最小版**（§4.3）: 接続を固定したハンドラを被せる。ネストは未対応。
   `TransientDbErr` / `DbErr` が飛べば ROLLBACK して再送出。実 PG で COMMIT / ROLLBACK を確認済み
8. [x] 層 5 のテスト `test/Pg/TestJdbc.flix`: 型の往復 / INSERT → SELECT / unique 違反 → conflict / 無いテーブル → schemaMismatch。
   `make test-pg` がコンテナの起動から停止までやる
9. [x] 多層ハンドラ（ログ → 計測 → インメモリ）の実行時間を 1 回測って `docs/spikes.md` に残した

**完了条件**: ユースケース関数のシグネチャに `\ {SqlRead, DbErr}` が出て、
インメモリハンドラでテストが書け、JDBC で実 PG に当たる。→ **達成**。残りは v1 へ。

## フェーズ 2: 層1 = v1（§3, §5）

1. [x] **`.q` パーサ**（`src/Q/QParser.flix`、AST は `QueryDef`）
   - `query 名前(引数) -> one | many | exec [keyed(col)] [with slot: 型, ...] { SQL }`
   - `:name` の宣言と使用の対応検査（未宣言・未使用・slot も同様・keyed は many だけ・同名禁止）
   - 機械置換で完全な SQL に戻す（`QRender.toSql`: `:id` → `$1`、`{filter}` → `TRUE`、`{order}` → 空）
2. [x] **スキーマ解決**（`Schema` / `DdlParser` / `QResolve`）: `migrations/*.sql` から机上のスキーマを組み、SELECT リストの列を名前・型・NULL 可否まで決める
   - DDL は CREATE TABLE / DROP TABLE / ALTER TABLE（ADD|DROP COLUMN、ALTER COLUMN の NOT NULL・TYPE、RENAME COLUMN）を読む。制約と CREATE INDEX は無視、それ以外は警告
   - 式の列は `expr::type AS name` の形だけ（型推論はしない）。LEFT / FULL JOIN の相手は NULL 可
3. [x] **codegen**（`Codegen` + `src/Main.flix` の `gen` サブコマンド、`make gen`）
   - クエリごとに行レコード + デコーダ（forA）+ 型付き関数（`one` → `Option[Row] \ {SqlRead, DbErr}`、`exec` → `Int32 \ SqlWrite`、RETURNING 付きの書き込みは `\ {SqlWrite, DbErr}`）
   - テーブルごとに断片 DSL 用の `Col` 定義（`Tables.flix`）
   - 生成物に `.q` のハッシュ（`sourceHash`）を埋め、テストで現物と照合する
4. [x] **断片 DSL の最小版**（`Fragment`）: `Col[row, a]` / `Pred[row]` / `Order[row]`、
   `eq ne lt le gt ge like isNull isNotNull inList both either negate when all` / `asc desc then`
   - render は (SQL, パラメータ列) を返す再帰。括弧は全付け。`$n` は本文の引数の続き番号
   - `RawSql` エフェクトで生 SQL を標識化（`Fragment.rawPred`、`RawSql.runWithAllow`）
5. [ ] **CI 検証**: 実 PG に全 `.q` を `PREPARE`（実行なし）
6. [x] デモプロジェクト `examples/blog/`（flix.toml 付きの独立プロジェクト。migrations + .q + 生成物 + ユースケース、
   生成コード版と生 SQL 版の 2 系統で DB 無し / 実 PG のテスト。本体は `make vendor` で src/sqlfx/ に写す）

残り: 5。`keyed` からの preloader 生成はフェーズ 3。

## フェーズ 3: 層2 = v2（§4.3, §6）

0. スパイク: 行多相レコード + trait 越しの型推論と、そのエラーメッセージ（preloader がフィールドを型に生やす形）
1. `keyed(col)` から preloader を生成。`users |> withPosts` で行多相レコードにフィールドが型として生える（スパイクの結果次第で形を決める）
2. JSON 集約（`:json` アノテーション → ネストしたレコードへデコード。精度が要る列は `::text`）
3. `withTx` 完成: ネスト（セーブポイント or 型エラー、ここで決める）・読み取り専用・分離レベル
4. `streamQuery`（fetchSize + 1 行ずつ継続）
5. `reclassify` ハンドラ（文脈依存の再分類。Unit 戻りの「その場から再開」はここで使う）

## フェーズ 4: マイグレーション = v3（§8）

1. 履歴テーブル（version + checksum）、昇順適用、歯抜け・改竄検出
2. `applyOne` を DDL トランザクションで包む。`-- sqlfx: no-tx` 注釈
3. `plan` / `analyzeImpact` は純粋関数（DB 無しでテスト）
4. `migrate --dry`: 机上でスキーマを進め、壊れる `.q` を列挙（フェーズ 2 の検証器を再利用）+ DDL 危険度警告
5. 起動時のスキーマハッシュ照合 → `DbErr.schemaMismatch`

## フェーズ 5: v4

- LSP（`.q` パーサの上。ブロック内は SQL としてカラム補完）
- EXPLAIN のテスト統合（seq scan 警告・コスト回帰）
- ドキュメント（README を層ごとの入門に書き直す）

## 未決事項（§12）を決めるタイミング

| 未決 | 決めるフェーズ | 決め方 |
|---|---|---|
| Tx ネスト（セーブポイント vs 型エラー） | 3 | フェーズ 1 では型エラー固定 |
| 断片 DSL の演算子セット | 2 | 上の最小セットから始め、サンプルアプリで足りない物を足す |
| `Pred[users]` の row 型の付け方 | 3 の前のスパイク | codegen が吐くマーカー型を試す |
| `streamQuery` の each に許すエフェクト | 3 | |
| `reclassify` の API 形状 | 3 | |
| `.q` の `with` 節に Order 以外を許す範囲 | 2 | 最初は `Pred` / `Order` だけ |

決まった物: `SqlRead.fetch` / `SqlWrite.execute`（op 名）、エラーは Transient / DbErr の 2 分類で全 op Void（業務エラーはアプリ側）、
`SqlValue` 1 つで行きと帰りを表す（いずれも `docs/layer0.md`）。

## ディレクトリ（予定）

```
src/Db/           層0: SqlValue / Row / Decoder / Sql（eff）/ DbError / Retry / Tx（モジュールはトップレベルに平ら）
src/Db/Jdbc/      JDBC ハンドラ（腐敗防止層）
src/Db/Test/      テストハンドラ 3 種（本体に同梱。利用側のテストで使う）
src/Q/            層1: .q パーサ（QParser）/ スキーマ解決（Schema, DdlParser, QResolve）/ 断片 DSL（Fragment）/ 生成器（Codegen）
src/Main.flix     `gen` サブコマンド（bin/flix run -- gen <migrations> <queries> <out>）
src/Db/Migrate/   層2〜: マイグレーション
test/Example/     層0 だけの小さな見本（`mod ExampleUsers`）
examples/blog/    デモプロジェクト（独立。examples/blog/README.md）
test/             src と同じ構成。DB 無しで回る
test/Pg/          実 PG が要るテスト。make test-unit は build/unit/ に Pg 抜きの写しを作って回す
```
