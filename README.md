# sqlfx

Flix の PostgreSQL 向け DB ライブラリ。SQL はそのまま書き、文と文の**間**にエフェクトで型を付ける。

```
                 アプリのコード                                    型に出る物
   ┌─────────────────────────────────────────────┐
   │  def removeUser(id): Bool \ DbWrite          │   ← 書く。失敗しうる
   │      discard deletePostsOfUser(id)           │
   │      softDeleteUser(id) > 0                  │
   └─────────────────────────────────────────────┘
        │ SqlWrite.execute（op）
        ▼
   ┌──────────── ハンドラ（差し替え自由）────────────┐
   │  Jdbc.withConnection   本番。PostgreSQL へ      │
   │  DbTest.runWithRows    単体。決めた行を返す      │
   │  DbTest.runRecording   発行した SQL を記録       │
   └─────────────────────────────────────────────┘
```

- 読むだけの関数は `\ DbRead`、書く関数は `\ DbWrite`。読む関数の中で書くとコンパイルエラー
- 本番・単体・記録の切り替えはハンドラを被せ替えるだけ。関数側にもテスト側にも仕掛けが要らない
- DB のエラーはエフェクト。拾いたい所でだけ拾い、他はそのまま上へ流れる
- `.q` ファイルに素の SQL を書くと、型付きの関数とデコーダを生成する

設計は [docs/design.md](docs/design.md)、実装の詳細は [docs/layer0.md](docs/layer0.md)（生 SQL の層）と [docs/layer1.md](docs/layer1.md)（`.q` と生成器）。
動く例は [examples/blog](examples/blog/README.md)。

## 目次

1. [準備](#1-準備)
2. [生 SQL で使う](#2-生-sql-で使う)
3. [`.q` から関数を生成する](#3-q-から関数を生成する)
4. [`.q` の書き方](#4-q-の書き方)
5. [動的な条件（断片 DSL）](#5-動的な条件断片-dsl)
6. [エラーの扱い](#6-エラーの扱い)
7. [Tx と再実行](#7-tx-と再実行)
8. [テストの書き方](#8-テストの書き方)
9. [make の一覧とディレクトリ](#9-make-の一覧とディレクトリ)

## 1. 準備

前提: JDK 17 以上、Docker（実 PG のテスト用）、Flix 0.75.3 の jar。`bin/flix` は flix_game_engine の devbox の jar を探すが、
`FLIX_JAR=/path/to/flix.jar` を渡せばそれを使う。

```bash
make check       # 型検査
make test-unit   # DB 無しのテスト
make test-pg     # docker compose で PostgreSQL 16 を立て、全部回して、止める
```

利用側のプロジェクトは `flix.toml` に pgjdbc を書き、本体を `src/sqlfx/` に写す（`examples/blog/Makefile` の `vendor`）。
本体を GitHub にリリースしたら `[dependencies]` に切り替える。

```toml
[mvn-dependencies]
"org.postgresql:postgresql" = "42.7.4"
```

## 2. 生 SQL で使う

一番下の層。`Sql.fetch` / `Sql.execute` に SQL とプレースホルダの値を渡す。プレースホルダは `$1` 形式で、psql や EXPLAIN にそのまま貼れる。

```flix
use SqlValue.SqlValue

def renameUser(user: { id = Int64, name = String }): Int32 \ DbWrite =
    Sql.execute("UPDATE users SET name = $1 WHERE id = $2", List#{SqlValue.Str(user#name), SqlValue.Int64(user#id)})
```

結果は `Row` の列で返る。型を付けて受けるには `Decoder` を `forA` で組み、`Sql.fetchAs` に渡す。

```flix
pub type alias User = { id = Int64, name = String, email = Option[String] }

def userDecoder(): Decoder[User] =
    forA (
        id <- Decoder.int64("id");
        name <- Decoder.str("name");
        email <- Decoder.opt(Decoder.str("email"))      // NULL を None に
    ) yield { id = id, name = name, email = email }

def findUserByEmail(email: String): Option[User] \ DbRead =
    Sql.fetchOneAs(userDecoder(), "SELECT id, name, email FROM users WHERE email = $1", List#{SqlValue.Str(email)})

def registerUser(user: { name = String, email = String }): Option[Int64] \ DbWrite =
    Sql.executeReturningOneAs(Decoder.int64("id"),
        "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id",
        List#{SqlValue.Str(user#name), SqlValue.Str(user#email)})
```

| 関数 | 返す物 | 効果 |
|---|---|---|
| `Sql.fetch` / `fetchOne` | `List[Row]` / `Option[Row]` | `DbRead` |
| `Sql.fetchAs` / `fetchOneAs` | デコードした値 | `DbRead` |
| `Sql.execute` | 影響行数 `Int32` | `DbWrite` |
| `Sql.executeReturningAs` / `executeReturningOneAs` | RETURNING の行をデコードした値 | `DbWrite` |

デコードに失敗すると `DbErr.decodeError` が上がる。列が無い、型が違う、NULL 不可の列が NULL、の 3 種類で、静かに壊れない。

値の型は `SqlValue` の 1 つの enum で、行きも帰りも同じ:

```
Null  Bool  Int32  Int64  Float64  Decimal(BigDecimal)  Str  Bytes
Timestamp(epoch µs, UTC)  Date(epoch day)  Uuid  Json  Int64Array  StrArray
```

実行するには接続を開いて被せる:

```flix
def main(): Unit \ IO =
    let config = { url = "jdbc:postgresql://127.0.0.1:5432/sqlfx", user = "flix", password = "flix" };
    match DbError.runWithFailure(() -> Jdbc.withConnection(config, _ -> findUserByEmail("alice@example.com"))) {
        case Ok(user) => println("${Option.map(u -> u#name, user)}")
        case Err(failure) => println("db failed: ${failure}")
    }
```

## 3. `.q` から関数を生成する

生 SQL の層で毎回書くデコーダと `SqlValue` の包み直しを、生成器に任せる。

```
   migrations/*.sql ──┐
                      ├──▶  bin/flix run -- gen migrations/ queries/ src/Gen/
   queries/*.q ───────┘             │
                                    ▼
                         src/Gen/Tables.flix         テーブルごとの列（断片 DSL 用）
                         src/Gen/UsersQueries.flix   users.q の関数・行レコード・デコーダ
                         src/Gen/PostsQueries.flix
```

migrations の DDL から机上のスキーマを組み、`.q` の SELECT を当てて結果の列の名前・型・NULL 可否を決める。
テーブルや列が無ければ生成時に止まる。生成物には `.q` のハッシュが入り、`gen --check` で「生成し忘れ」を検知できる。

```bash
make gen         # 生成する
make gen-check   # 書かずに、生成物が最新かだけ確かめる（CI 用）
```

`.q` の 1 つがこう:

```
query findUser(id: Int64) -> one {
    SELECT id, name, email, role FROM users WHERE id = :id AND deleted_at IS NULL
}
```

生成される関数がこう:

```flix
pub type alias FindUserRow = { id = Int64, name = String, email = Option[String], role = String }
pub def findUser(id: Int64): Option[FindUserRow] \ DbRead
```

引数が 2 つ以上ならレコードで受ける。同じ型が並んでも取り違えない。

```flix
UsersQueries.insertUser({ name = "alice", email = "alice@example.com", role = "member" })
```

## 4. `.q` の書き方

```
// 行コメント
query 名前(引数: 型, ...) -> one | many | exec [keyed(列)] [with slot: Pred[テーブル] | Order[テーブル], ...] {
    素の SQL。:name で引数、{slot} で断片
}
```

| 形 | 返る物 | 使える文 |
|---|---|---|
| `-> one` | `Option[Row]` | SELECT、`RETURNING` 付きの INSERT / UPDATE / DELETE |
| `-> many` | `List[Row]` | 同上 |
| `-> exec` | `Int32`（影響行数） | `RETURNING` 無しの INSERT / UPDATE / DELETE |

引数の型は Flix の綴り: `Bool Int32 Int64 Float64 BigDecimal String Bytes Timestamp Date Uuid Json List[Int64] List[String]`。

バリエーション:

```
// 1 行を取る
query findUser(id: Int64) -> one {
    SELECT id, name, email, role FROM users WHERE id = :id
}

// 配列で IN 句。keyed は「この列で束ねる」印（preloader 用）
query postsByUsers(ids: List[Int64]) -> many keyed(user_id) {
    SELECT id, user_id, title FROM posts WHERE user_id = ANY(:ids) ORDER BY id
}

// JOIN。alias 付きの列は AS で名前を付ける。LEFT JOIN の相手は Option になる
query postWithAuthor(id: Int64) -> one {
    SELECT p.id, p.title, u.name AS author_name, u.email AS author_email
    FROM posts AS p JOIN users AS u ON u.id = p.user_id
    WHERE p.id = :id
}

// 式の列は ::type AS name で型を書く（推論はしない）
query countUsers() -> one {
    SELECT count(*)::bigint AS total FROM users WHERE deleted_at IS NULL
}

// 書いて id を返す
query insertUser(name: String, email: String, role: String) -> one {
    INSERT INTO users (name, email, role) VALUES (:name, :email, :role) RETURNING id
}

// 影響行数だけ
query softDeleteUser(id: Int64) -> exec {
    UPDATE users SET deleted_at = now() WHERE id = :id AND deleted_at IS NULL
}

// 動的な条件と並び順を差し込む（§5）
query searchUsers(limit: Int64) -> many
    with filter: Pred[users], order: Order[users]
{
    SELECT id, name, email, role FROM users
    WHERE deleted_at IS NULL AND {filter}
    {order}
    LIMIT :limit
}
```

決まり:

- `:name` は宣言に無いとエラー、宣言して使わないのもエラー。`'...'` の中と `::text` は触らない
- 同じ `:name` を 2 回書けば同じ `$n` になる
- `--` から行末はコメント
- query 名・引数名・slot 名は Flix の識別子になるので、予約語（`type` `alias` `run` など）と内部名（`sql` `params`）は生成時にエラー
- 読める DDL は CREATE TABLE / DROP TABLE / ALTER TABLE の ADD・DROP・ALTER COLUMN・RENAME COLUMN。制約と INDEX は無視、他は警告

## 5. 動的な条件（断片 DSL）

`{slot}` に入れる述語と並び順を、型付きの値として組む。列は生成された `UsersTable.name()` のような物からしか来ないので、識別子の混入が起きない。値は必ず `$n` になる。

```flix
def activeUsersNamed(search: { prefix = String, limit = Int64 }): List[SearchUsersRow] \ DbRead =
    UsersQueries.searchUsers(
        search#limit,
        Fragment.when(search#prefix != "", Fragment.like(UsersTable.name(), search#prefix + "%")),
        Fragment.asc(UsersTable.name()))
```

```
  searchUsers(10, filter, order)
     │
     │  filter = both(isNull(deletedAt), like(name, "a%"))
     │  order  = then(asc(name), desc(id))
     ▼
  SELECT ... WHERE deleted_at IS NULL AND ((deleted_at IS NULL) AND (name LIKE $2))
             ORDER BY name ASC, id DESC
             LIMIT $1                                  params: [10, "a%"]
```

| 述語 | 並び順 |
|---|---|
| `eq ne lt le gt ge like isNull isNotNull inList` | `asc desc then` |
| `both either negate`（`and` `or` `not` は予約語） | `unordered()` |
| `when(cond, pred)` `all(preds)` `any(preds)` `always()` | |

`both` は `always()` を消して繋ぐので、`when` が偽のときに `TRUE AND` が SQL に残らない。`inList` の空は `FALSE`。
生 SQL を断片に入れたいときは `Fragment.rawPred(sql)` で、呼ぶ側に `RawSql` エフェクトが付く（監査箇所が型から列挙できる）。

## 6. エラーの扱い

DB のエラーは 2 つのエフェクト。どちらの op も戻らない（`Void`）。

```
TransientDbErr   deadlock / timeout / connectionLost         再実行で直りうる → withRetry
DbErr            uniqueViolation / foreignKeyViolation /      直らない
                 schemaMismatch / decodeError / retryExhausted / other
```

拾いたい所でだけ拾う。`DbError.runWithKind` で値にし、業務の判断をして、他は `DbError.raise` で流す。

```flix
pub enum RegisterError with Eq, ToString {
    case EmailTaken(String)
}

pub def registerUser(user: NewUser): Result[RegisterError, Int64] \ DbWrite =
    match DbError.runWithKind(() -> UsersQueries.insertUser({ name = user#name, email = user#email, role = "member" })) {
        case Ok(Some(row)) => Ok(row#id)
        case Ok(None) => DbErr.other("INSERT ... RETURNING returned no row")
        case Err(DbErrorKind.UniqueViolation("users_email_key")) => Err(RegisterError.EmailTaken(user#email))
        case Err(kind) => DbError.raise(kind)
    }
```

境界（main / HTTP ハンドラ / テスト）で 1 層の `Result` にするには `DbError.runWithFailure`。
制約名は pgjdbc の `ServerErrorMessage` から取るので、PG のロケールに依存しない。

## 7. Tx と再実行

```flix
Jdbc.withConnection(config, conn ->                 // 開いて、必ず閉じる
    Retry.withRetry(3, () ->                        // Transient なら thunk を最初から呼び直す
        Tx.withTx(conn, () ->                       // BEGIN / COMMIT。失敗なら ROLLBACK して再送出
            Blog.removeUser(1i64))))
```

```
   withRetry ─┬─ attempt 1: withTx ─ BEGIN ─ DELETE ─ UPDATE ─ deadlock ─ ROLLBACK
              ├─ attempt 2: withTx ─ BEGIN ─ DELETE ─ UPDATE ─ COMMIT ─▶ 値
              └─ 枯渇したら DbErr.retryExhausted
```

再実行は Tx 単位。PG はデッドロック後に Tx 全体が aborted になるので、文単位の再実行は意味を持たない。
COMMIT で初めて出るエラー（遅延制約など）も翻訳し、接続は autocommit に戻る。ネストは v0 では未対応。

## 8. テストの書き方

同じ関数を、ハンドラを変えて走らせる。関数側は変えない。

```flix
// 決めた行を返す。デコードとロジックを見る
DbError.runWithFailure(() -> DbTest.runWithRows(rows, () -> findUserByEmail("alice@example.com")))

// SQL ごとに返す行を変え、発行した文を記録する。N+1 の回帰を件数で止める
let (grouped, statements) = DbTest.runRecordingWith(rowsFor, 0, () -> DbError.runWithFailure(() -> Blog.usersWithPosts(10i64)));
Assert.assertEq(expected = 2, List.length(statements))

// DB の失敗を返すハンドラを書けば、業務エラーへの変換も DB 無しで確かめられる
run {
    DbError.runWithFailure(() -> Blog.registerUser({ name = "alice", email = "alice@example.com" }))
} with handler SqlWrite {
    def execute(_sql, _params, resume) = resume(Ok(0))
    def executeReturning(_sql, _params, resume) = resume(Err(DbErrorKind.UniqueViolation("users_email_key")))
}
```

実 PG のテストは `test/Pg/` に置き、`make test-pg` がコンテナを立てて回す。決まったテストデータを入れてから、各クエリの結果を丸ごと比べる形が読みやすい（`examples/blog/test/Pg/TestQueriesPg.flix`）。
Flix のレコードは `Eq` を持たないので、期待値は `Views.user({ id = ..., name = ... })` のように enum に写して比べる。

## 9. make の一覧とディレクトリ

```bash
make check         # 型検査
make test          # フル（test-unit → test-pg → test-examples）
make test-unit     # DB 無し。build/unit/ に test/Pg 抜きの写しを作って回す（元のファイルには触らない）
make test-pg       # 実 PG。docker compose で立てて、全部回して、止める
make test-examples # examples/blog（独立プロジェクト）のテスト
make gen           # examples/blog の migrations と .q から生成
make gen-check     # 生成物が最新か（書かない）
make db-up / db-down   # 手動で PG を触りたいとき
```

```
src/Db/           層0: SqlValue / Row / Decoder / Sql / DbError / Retry / Tx / Preload
src/Db/Jdbc/      JDBC ハンドラ（腐敗防止層）。sqlstate の翻訳表もここ
src/Db/Test/      テストハンドラ（runWithRows / runWithTable / runRecording / runLogging）
src/Q/            層1: .q パーサ / スキーマ解決 / 断片 DSL / 生成器
src/Main.flix     `gen` サブコマンド
test/             DB 無しのテスト。test/Pg/ だけ実 PG が要る
examples/blog/    デモ。flix.toml を持つ独立プロジェクト。生成コード版と生 SQL 版を並べてある
docs/             design.md（設計）/ layer0.md / layer1.md（実装メモ）/ spikes.md（Flix で踏んだ制約）
```

VSCode の Flix 拡張は `src/` と `test/` しか LSP に渡さないので、`examples/blog` を触るときは別ウィンドウで開く。
