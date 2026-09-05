# 層0 の API 設計

[design.md](design.md) の §4・§7 を、実装できる粒度の型と関数名に落とした物。
ここに書いた名前が正で、実装中に変えたらここも直す。

言葉は sqlx / Ecto / JDBC の語に寄せる（`fetch` / `execute` / `Row` / `Decoder` / `Statement`）。
予約語（`query` / `select` / `where` / `run` / `from` / `into`）は識別子に使わない。

モジュールはトップレベルに平らに置く（`SqlValue` / `Row` / `Decoder` / `Sql` / `DbError` / `Jdbc` / `DbTest`）。
`Db.SqlValue` のようなドット付きモジュールは 0.75.3 で型が解決されず、`mod Db { ... }` は 1 ファイルにしか
書けない（[spikes.md](spikes.md)）ため。ファイルは `src/Db/` 以下に置く。

## 全体像

```
ユースケース関数  \ {SqlRead, DbErr}
      │  SqlRead.fetch(sql, params) : List[Row]
      ▼
ハンドラ（差し替え可能）
  DbTest.runWithRows   固定 Row を返す（層 2 のテスト）
  DbTest.runRecording  発行 Statement を記録（層 3 のテスト）
  DbTest.runLogging    Sql を包んで Logger へ流す中間ハンドラ
  Jdbc.runWithConnection   java.sql へ（本番）
      │
      ▼
Decoder（純粋）  Row -> Result[DecodeError, a]
```

## モジュールとファイル

| ファイル | 中身 |
|---|---|
| `src/Db/SqlValue.flix` | `enum SqlValue`。行き（プレースホルダ）と帰り（セル）の両方 |
| `src/Db/Row.flix` | `Row` / `ColumnIndex` / `Statement` |
| `src/Db/Decoder.flix` | `Decoder[a]` と組み合わせ関数 |
| `src/Db/Sql.flix` | `eff SqlRead` / `eff SqlWrite` |
| `src/Db/DbError.flix` | `eff TransientDbErr` / `eff DbErr` / `enum DbErrorKind` / `enum DbFailure` |
| `src/Db/Retry.flix` | `Retry.withRetry` |
| `src/Db/Tx.flix` | `Tx.withTx` |
| `src/Db/Jdbc/SqlState.flix` | `mod SqlState`: sqlstate → `DbErrorKind`（純粋） |
| `src/Db/Jdbc/JdbcConvert.flix` | `mod JdbcConvert`: `SqlValue` ⇔ JDBC の変換（Java 型はここに閉じる） |
| `src/Db/Jdbc/Jdbc.flix` | `mod Jdbc`: `runWithConnection` |
| `src/Db/Test/DbTest.flix` | `runWithRows` / `runRecording` / `runLogging`（1 モジュール 1 宣言なので 1 ファイル） |

## 値: `SqlValue`

```flix
///
/// プレースホルダに渡す値と、行のセルの値。行きと帰りで同じ型を使い、JDBC との型対応表を 1 つにする。
/// Java の型を payload に持たない（Eq を derive し、テストハンドラで記録した Statement を比較できるように）。
///
pub enum SqlValue with Eq, Order, ToString {
    case Null
    case Bool(Bool)
    case Int32(Int32)
    case Int64(Int64)
    case Float64(Float64)
    case Decimal(BigDecimal)       // NUMERIC。金額など精度が要る列
    case Str(String)
    case Bytes(Vector[Int8])       // BYTEA
    case Timestamp(Int64)          // TIMESTAMPTZ。UTC の epoch マイクロ秒
    case Date(Int32)               // DATE。1970-01-01 からの日数
    case Uuid(String)              // 36 文字の文字列表現
    case Json(String)              // JSON / JSONB。素の文字列。構造化は層 2
    case Int64Array(List[Int64])   // ANY(:ids) 用。他の配列型は要るときに足す
    case StrArray(List[String])
}
```

- `Timestamp` を `Int64` にするのは、`OffsetDateTime` を持つと `Eq` が消えるから。
  `java.time` との変換は `JdbcConvert` の内側にだけ置く
- 型ごとの取り出し（`asInt64: SqlValue -> Option[Int64]` 等）はここに置き、`Decoder` から使う

## 行: `Row` / `ColumnIndex` / `Statement`

```flix
/// 列名 → 添字。同じ結果セットの行はこれを共有する（行ごとに Map を持たない）。
pub type alias ColumnIndex = Map[String, Int32]

/// 結果セットの 1 行。接続からは切り離された不変の値。
pub type alias Row = { columns = ColumnIndex, cells = Vector[SqlValue] }

/// 発行した文。計測ハンドラが記録し、テストで比較する。
pub type alias Statement = { sql = String, params = List[SqlValue] }
```

`Row.get(name, row): Option[SqlValue]`（列が無ければ None）。
`Row.makeRows(names: List[String], cells: List[List[SqlValue]]): List[Row]` はテストと JDBC の両方が使う組み立て関数。

## デコーダ: `Decoder[a]`

```flix
/// 1 行を型付きの値に変える純粋関数。失敗は列名と理由を持つ。
pub enum Decoder[a](Row -> Result[DecodeError, a])

pub enum DecodeError with Eq, ToString {
    case MissingColumn(String)               // 列が結果セットに無い
    case TypeMismatch(String, String, String) // 列名, 期待した型, 実際の型
    case UnexpectedNull(String)
}
```

組み合わせ関数（全部純粋。`Decoder` モジュール）:

| 関数 | 型 |
|---|---|
| `int32(name)` / `int64(name)` / `str(name)` / `bool(name)` / `float64(name)` / `decimal(name)` / `bytes(name)` / `timestamp(name)` / `date(name)` / `uuid(name)` / `json(name)` / `int64Array(name)` / `strArray(name)` | `String -> Decoder[a]` |
| `column(name)` | `String -> Decoder[SqlValue]`（型を決めずに取る） |
| `flatMap(f, d)` | `(a -> Decoder[b]) -> Decoder[a] -> Decoder[b]` |
| `opt(d)` | `Decoder[a] -> Decoder[Option[a]]`（Null を None に） |
| `map(f, d)` | `(a -> b) -> Decoder[a] -> Decoder[b]` |
| `ap(df, da)` | `Decoder[a -> b] -> Decoder[a] -> Decoder[b]`（複数列をレコードへ） |
| `pure(x)` | `a -> Decoder[a]` |
| `decodeRow(d, row)` | `Decoder[a] -> Row -> Result[DecodeError, a]` |
| `decodeRows(d, rows)` | `Decoder[a] -> List[Row] -> Result[DecodeError, List[a]]`（最初に失敗した行で止まる） |

`decodeRow` / `decodeRows` は純粋（`Result`）。`DbErr.decodeError` への持ち上げは `Sql` 側の `fetchAs` で行う（デコード失敗は「静かな半壊」の代表なので即 DbErr）。
列名 → 添字の解決は `ColumnIndex` の `Map.get` で、行ごとに O(log n)。「compile 時に 1 回」の
最適化は層 1 の codegen が添字を直接埋める形で行い、層0 では行わない。

## エフェクト: `SqlRead` / `SqlWrite`

```flix
pub eff SqlRead  { def fetch(sql: String, params: List[SqlValue]): List[Row] }
pub eff SqlWrite { def execute(sql: String, params: List[SqlValue]): Int32 }
```

- `fetch` は結果を全部 materialize して返す。大量データの `streamQuery` は層 2 で別 op
- プレースホルダは PG 流の `$1` `$2` で書く（psql / EXPLAIN にそのまま貼れる）。pgjdbc は `?` しか解釈しないので、
  JDBC ハンドラが `JdbcConvert.rewritePlaceholders`（純粋）で `?` に書き換え、出現順にパラメータを並べ直す。
  同じ `$1` を 2 回書けば値も 2 回送る。params に無い `$n` は `DbErr.corrupt`
- `one` 相当（`Option[Row]`）は `fetch` の上の関数 `Sql.fetchOne` で作る（op を増やさない）
- `Sql.fetchAs(decoder, sql, params): List[a] \ {SqlRead, DbErr}` と `Sql.fetchOneAs` がデコードまで行い、
  失敗は `DbErr.decodeError` に持ち上げる

## エラー 2 分類

```flix
pub eff TransientDbErr {
    def deadlock(): Void
    def timeout(ms: Int32): Void
    def connectionLost(msg: String): Void
}
pub eff DbErr {
    def uniqueViolation(constraint: String): Void
    def foreignKeyViolation(constraint: String): Void
    def schemaMismatch(detail: String): Void
    def decodeError(column: String, detail: String): Void
    def retryExhausted(last: String): Void
    def corrupt(detail: String): Void
}
```

全 op が `Void`。理由は design.md §4.2。「見つからない」のような業務の判断はライブラリのエフェクトにせず、
0 行は `Option` で返す。

JDBC ハンドラは `SQLException` を直接 op に翻訳せず、まず純粋な enum に落とす:

```flix
/// sqlstate をどの op に翻訳するか。翻訳表は DB 無しでテストする。
pub enum DbErrorKind with Eq, Order, ToString {
    case Conflict(String)        // 23505 → DbErr.uniqueViolation
    case InvalidRef(String)      // 23503 → DbErr.foreignKeyViolation
    case Deadlock                // 40001, 40P01
    case Timeout(Int32)          // 57014（statement_timeout）。ms が分からなければ 0
    case ConnectionLost(String)  // 08xxx
    case SchemaMismatch(String)  // 42P01, 42703, 42883, 42804
    case Corrupt(String)         // その他
}
pub def classify(sqlState: String, message: String): DbErrorKind
```

`DbError.raise(kind)` が enum を対応する op に変えて投げる。

業務コードは Result を返さず、エフェクトのまま上へ流す。境界で値にしたいときは 2 つの落とし方がある:

- `DbError.runWithFailure(thunk): Result[DbFailure, a] \ ef - {TransientDbErr, DbErr}`
  2 分類をまとめて **1 層** の Result にする。`DbFailure` は `Transient(String)` / `Permanent(String)`。
  テストと main はこれを使う
- 各エフェクトの companion モジュールの `runWithResult(thunk): Result[String, a] \ ef - X`
  （`DbErr.runWithResult` / `TransientDbErr.runWithResult`）。片方だけ値にして、もう片方は上へ流したいとき向け

ログを出して終わるだけなら Result にせず `with handler DbErr { ... }` を直接書けばよい（Void 戻りの op は
継続を呼ばないので、値の型は変わらない）。

## ハンドラ

型の形（`ef - SqlRead` の書き方は Flix の効果差分）:

```flix
mod DbTest {
    /// 固定の行を返す。どの SQL にも同じ rows を返す最小版
    pub def runWithRows(rows: List[Row], thunk: Unit -> a \ ef): a \ ef - SqlRead

    /// SQL 文字列ごとに返す行を変える。None の SQL は空の結果
    pub def runWithTable(table: String -> Option[List[Row]], thunk: Unit -> a \ ef): a \ ef - SqlRead

    /// 発行した Statement を順に記録して返す。SqlRead には rows を、SqlWrite には affected を返す
    pub def runRecording(rows: List[Row], affected: Int32, thunk: Unit -> a \ ef): (a, List[Statement]) \ ef - {SqlRead, SqlWrite}

    /// Sql を包み、発行前後を Logger へ流してから内側の Sql へ転送する。ハンドラ合成の見本
    pub def runLogging(thunk: Unit -> a \ ef): a \ ef + {SqlRead, SqlWrite, Logger}
}

mod Jdbc {
    /// 1 本の接続で fetch / execute を実行する。結果は即時 materialize する
    pub def runWithConnection(conn: Connection, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr}
}
```

規約: ハンドラは継続 `k` を必ず 1 回だけ呼ぶ（`fetch` の結果を返すか、エラー op を投げて呼ばないか）。

## `withRetry` と `withTx`

```flix
/// Transient で失敗したら thunk を最初から呼び直す。attempts 回で枯渇したら DbErr.retryExhausted
pub def Retry.withRetry(attempts: Int32, thunk: Unit -> a \ ef): a \ (ef - TransientDbErr) + DbErr

/// BEGIN してから thunk を同じ接続で走らせ、正常なら COMMIT、Transient / DbErr が飛べば ROLLBACK して再送出
pub def Tx.withTx(conn: Connection, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr}
```

- `withRetry` の外側の型から `TransientDbErr` は消える（全部捕まえて、枯渇だけ DbErr にする）。
  backoff は v0 では無し（待つ手段が IO を要求し、純粋なテストで回せなくなる）
- `withTx` は内側に `Jdbc.runWithConnection` を被せるので、thunk の `SqlRead` / `SqlWrite` は同じ接続で走る
- v0 のネストは未対応（同じ接続で内側の `withTx` を呼ぶと内側の COMMIT で外側も確定する）。
  セーブポイントか型で禁止するかは v2 で決める
- 組み合わせは `Retry.withRetry(3, () -> Tx.withTx(conn, body))` の順（リトライ単位 = Tx 単位）

## サンプル（`test/Example/ExampleUsers.flix`）

本体は純粋な DB ライブラリなので、使い方の見本は test 側に置く。シグネチャがドキュメントになる形:

```flix
pub type alias User = { id = Int64, name = String, email = Option[String] }

pub def userDecoder(): Decoder[User] =
    Decoder.pure(id -> name -> email -> { id = id, name = name, email = email })
        |> Decoder.ap(Decoder.int64("id"))
        |> Decoder.ap(Decoder.str("name"))
        |> Decoder.ap(Decoder.opt(Decoder.str("email")))

/// 読むだけ・0 行は None・DB エラーは上へ流す、がシグネチャに出る
pub def findUser(id: Int64): Option[User] \ {SqlRead, DbErr} =
    Sql.fetchOneAs(userDecoder(), "SELECT id, name, email FROM users WHERE id = $1", List#{SqlValue.Int64(id)})

/// 書くので SqlWrite が出る
pub def renameUser(id: Int64, name: String): Bool \ SqlWrite
```

テストではハンドラを被せて 1 層の Result に落とす:

```flix
DbError.runWithFailure(() -> DbTest.runWithRows(rows, () -> ExampleUsers.findUser(1i64)))
// => Ok(Some(user)) / Ok(None) / Err(DbFailure.Permanent("..."))
```

本番は `Jdbc.connect` で接続を開き、`Retry.withRetry(3, () -> Tx.withTx(conn, () -> ...))` の中で同じ関数を呼ぶ。

## テストの置き場

| 層 | 場所 | 対象 |
|---|---|---|
| 1 | `test/Db/TestSqlValue.flix` / `TestDecoder.flix` / `test/Db/Jdbc/TestSqlState.flix` | 純粋関数 |
| 2 | `test/Example/TestUsers.flix` / `test/Db/TestDbTest.flix` | `runWithRows` でユースケースを検証 |
| 3 | 同上 | `runRecording` でクエリ数の上限（`assertLe`）と発行 SQL |
| 5 | `test-pg/TestJdbc.flix` | 実 PG に当たる。`make test-pg` がコンテナを立てて `test/Pg/` へ写して回し、止める。DSN が無ければ `bug!` |
