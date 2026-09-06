# スパイクの結果

Phase 0 のスパイクと、実装中に分かった Flix 0.75.3 の制約。スパイクのファイル自体は結果を残して消した。

| 日付 | スパイク | 結果 |
|---|---|---|
| 2026-09-06 | (a) エフェクト集合の `type alias` | **使える**。`type alias Db = {SqlRead, DbErr}` を `\ Db` に書けて、ハンドラも個別に被せられる。`Db` alias は採用 |
| 2026-09-06 | (b) `spawn` 本体に自作エフェクト | **置けない**。`spawn` 本体は `(Chan + IO + NonDet) & e0` に限定される型エラー。Tx 内 spawn の禁止は言語側で保証済みなので、本ライブラリでは何もしない |
| 2026-09-06 | (c) Maven 依存の `org.postgresql.Driver` を直接ロード | **動く**。`new Driver()` → `driver.connect(url, props)` が接続拒否の `SQLException` まで到達（ローカルに PG が無いため接続自体は未確認）。`DriverManager` を経由しない方針で進める |

## 実測で分かった Flix の書き方

- `import` はファイルの先頭。doc コメント（`///`）を `import` より前に置くとパースエラーになる
- Java メソッドの戻り値は `let msg: String = e.getMessage();` のように型注釈が要る（無いと `JvmToType` の unify エラー）
- 単体の Flix ファイルは `bin/flix Foo.flix` で走る。Maven 依存が要る物はコンパイラの `-cp` では見えないので、
  プロジェクトの中（`test/`）に置いて回す

## 層0 実装中に分かった制約（2026-09-06）

- **モジュールは 1 宣言 1 か所**。`mod Db { ... }` を複数ファイルに分けると `Duplicate module: 'Db'`。
  `mod Db.SqlValue { enum SqlValue }` のドット付きも、関数は `Db.SqlValue.isNull` で引けるのに
  型 `Db.SqlValue.SqlValue` が `Undefined type` になる。→ モジュールはトップレベルに平らに置く
  （`SqlValue` / `Row` / `Decoder` ...）。ファイルの置き場は `src/Db/` のままでよい
- `mod Foo { pub enum Foo }` の型は `Foo.Foo`。`use Foo.Foo` で短くできる
- テストファイルの `use` はファイル先頭。`///` の doc コメントを `use` より前に置くとパースエラー（import と同じ）。
  ファイル見出しは `//` で書く
- 1 引数の enum で関数を包む newtype は `pub enum Decoder[a](Row -> Result[DecodeError, a])` と書け、
  `let Decoder.Decoder(f) = d` で取り出せる
- `BigDecimal` リテラルは `1.5ff`
- ドット付きモジュール `mod Example.Users` は関数の解決も落ちる（`Undefined name 'Example.Users.findUser'`）。
  トップレベルの `def` は全ファイルで 1 つの名前空間なので、テストの補助関数名もファイル間で衝突する
- エフェクトの companion モジュール（`mod DbErr { ... }`）は書ける。`runWithResult` をそこに置いた
- ハンドラの op 本体に `;` で文を並べるときは `{ }` で包む（包まないと `Expected '}' before ';'`）
- `Option.getOrElse` は無い。`match` か `Option.getWithDefault`
- レコードは `Eq` を持たないので、テストでは比較の前にタプルへ写す
- Java の `import` は **モジュールの中** に書く（トップレベルに書くと mod の中から見えない）。
  別名は `import java.sql.{Array => SqlArray}`（`as` は無い）
- Java メソッドの戻り値を Flix の値として使う所には型注釈が要る（`let s: String = rs.getString(i)`）。
  関数を返す関数の型は `(ResultSet -> SqlValue \ IO) \ IO` のように括弧で包む
- `Int64.div` / `Int64.rem` は無い。`/` と `Int64.remainder`（`Int32.remainder`）
- `Object[]` を渡すには `Array[Object, rc]` を `Array.empty` で作り `checked_cast(Long.valueOf(x))` で詰める。
  受け取る側は `java.sql.Array.getResultSet()` で ResultSet 経由にすればキャスト不要
- 環境変数は `Sys.Env.getVar(name): Option[String] \ Sys.Env`、`Sys.Env.runWithIO` で剥がす
- pgjdbc はプレースホルダを `?` としてしか解釈しない。`$1` を渡すと「列インデックスは範囲外です: 1, 列の数: 0」で
  bind に失敗する。→ `JdbcConvert.rewritePlaceholders` で `$n` → `?` に書き換えて送る
- 実 PG（postgres:16、docker compose）で NUMERIC / BOOLEAN / TIMESTAMPTZ / DATE / TEXT[] / JSONB / UUID / NULL の
  往復、BIGSERIAL、unique 違反 → conflict、無いテーブル → schemaMismatch を確認済み（2026-09-06、`make test-pg`）

## 多層ハンドラの実行性能（2026-09-06、インメモリ、20 万回 fetch、M 系 Mac）

| 構成 | 時間 | 1 回あたり |
|---|---|---|
| `runWithRows` だけ | 0 ms | 継続をそのまま返すだけの手続きはコンパイラが直接呼び出しに落とす |
| `runRecording`（Ref に記録） | 119 ms | 0.6 µs |
| `runLogging`（Logger を捨てる）→ `runRecording` | 263 ms | 1.3 µs |

JDBC の往復（数十〜数百 µs）に比べて 2 桁小さいので、ハンドラを重ねる設計の性能リスクは無い。
`runLogging` の増分は SQL とパラメータの文字列化がほとんど。

## ハンドラ本体で投げたエフェクトはどこに届くか（2026-09-06）

```flix
run { Ok(run { inner() } with handler Op { def op(_k) = Fail.fail() }) } with handler Fail { def fail(_k) = Err("caught outside") }
```
`inner` の中で `Fail` を被せていても、`Op` のハンドラ本体で投げた `Fail` は **外側** に届く（`Err(caught outside)`）。
ハンドラ本体は `run` の外側の文脈で評価される。なので JDBC ハンドラは失敗を値で継続に渡し、`Sql.*` が呼び出し側で op にする。

## 記号演算子として定義できる綴り（2026-09-06）

- `>` `<` `>=` `<=` `==` `!=` は組み込みの比較に固定。`pub def >(...)` は parse error、`use` で被せても組み込みが勝つ。`<=>` も予約済み
- 演算子に使える文字は `= < > ! | & $ ^ * - + /`。`.` `:` `~` は使えない（`>.` `>:` `=~` は lexer error）
- `===` `=!=` `<<` `<<=` `>>` `>>=` は定義できて中置で使える。`a Fragment.>> b` の修飾付き中置は書けず、`use Fragment.{>>}` が要る
- `>>` は Prelude の関数合成と同じ綴りだが、`use Fragment.{>>}` を書いた関数の中だけ列比較になり、書いていない関数では合成のまま
