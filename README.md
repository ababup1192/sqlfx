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
   │  Pool.withConnection   本番。PostgreSQL へ      │
   │  DbTest.runWithRows    単体。決めた行を返す      │
   │  DbTest.runRecording   発行した SQL を記録       │
   └─────────────────────────────────────────────┘
```

- 読むだけの関数は `\ DbRead`、書く関数は `\ DbWrite`。読む関数の中で書くとコンパイルエラー
- 本番・単体・記録の切り替えはハンドラを被せ替えるだけ。関数側にもテスト側にも仕掛けが要らない
- DB のエラーはエフェクト。拾いたい所でだけ拾い、他はそのまま上へ流れる
- `.q` ファイルに素の SQL を書くと、型付きの関数とデコーダを生成する

設計は [docs/design.md](docs/design.md)、実装の詳細は [docs/layer0.md](docs/layer0.md)（`Sql` / `Decoder` / エフェクト）と [docs/layer1.md](docs/layer1.md)（`.q` と生成器）。
動く例は [examples/blog](examples/blog/README.md)。

## 目次

1. [準備](#1-準備)
2. [`.q` から関数を生成する](#2-q-から関数を生成する)
3. [`.q` の書き方](#3-q-の書き方)
4. [動的な条件（断片 DSL）](#4-動的な条件断片-dsl)
5. [生 SQL で書く（逃げ道）](#5-生-sql-で書く逃げ道)
6. [エラーの扱い](#6-エラーの扱い)
7. [migrate](#7-migrate)
8. [Tx と再実行](#8-tx-と再実行)
9. [テストの書き方](#9-テストの書き方)
10. [make の一覧とディレクトリ](#10-make-の一覧とディレクトリ)

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

## 2. `.q` から関数を生成する

`.q` に SQL を書くと、行レコード・デコーダ・型付きの関数を生成器が出す。これが既定の道で、生 SQL（§5）は `.q` で書けない文のための逃げ道。

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

## 3. `.q` の書き方

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
`Timestamp` / `Date` / `Uuid` / `Json` は生成コードでも同じ名前の型になる（§5 の「日時と JSON」）。

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

## 4. 動的な条件（断片 DSL）

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
     │  order  = asc(name) |> thenDesc(id)
     ▼
  SELECT ... WHERE deleted_at IS NULL AND ((deleted_at IS NULL) AND (name LIKE $2))
             ORDER BY name ASC, id DESC
             LIMIT $1                                  params: [10, "a%"]
```

| 比較 | 述語 | 並び順 |
|---|---|---|
| `=== =!= << <<= >> >>=`（左は列、右は列か `value(x)`） | `like inList` | `asc desc` |
| | | `thenAsc thenDesc`（`asc(a) \|> thenDesc(b)` でキーを足す） |
| | `isNull isNotNull`（NULL 可の列だけ） | `unordered()` |
| | `both either negate`（`and` `or` `not` は予約語） | |
| | `when(cond, pred)` `all(preds)` `any(preds)` `always()` | |

`both` は `always()` を消して繋ぐので、`when` が偽のときに `TRUE AND` が SQL に残らない。`inList` の空は `FALSE`。

### 部分更新（`Changes`）

UPDATE の SET 句も slot にできる。編集フォームの「触った項目だけ書き換える」を、項目の組み合わせごとに query を書かずに済ませる。

```
query updatePost(id: Int64) -> exec with changes: Changes[posts] {
    UPDATE posts SET updated_at = now(), {changes} WHERE id = :id
}
```

```flix
type alias PostEdit = { title = Option[String], body = Option[String], published = Option[Bool] }   // None は「触っていない」

def editPost(id: Int64, edit: PostEdit): Int32 \ DbWrite =
    Fragment.noChange()
        |> Fragment.setIfSome(PostsTable.title(), edit#title)        // Some なら代入、None は触らない
        |> Fragment.setIfSome(PostsTable.body(), edit#body)
        |> Fragment.setIfSome(PostsTable.published(), edit#published)
        |> PostsQueries.updatePost(id)                               // SET updated_at = now(), title = $2 WHERE id = $1
```

| 関数 | SQL | 型で守る物 |
|---|---|---|
| `set(col, x)` | `col = $n` | 列と値の型 |
| `setNull(col)` | `col = NULL` | NULL 可の列だけ |
| `setIfSome(col, opt)` | Some なら `set`、None は触らない | フォームの未入力用 |
| `setOrNull(col, opt)` | Some なら `set`、None は `setNull` | 行型の `Option` を書き戻す用。NULL 可の列だけ |
| `increment(col, by)` | `col = col + $n` | 数値の列だけ |
| `rawSet(sql)` | そのまま | 呼ぶ側に `RawSql` が付く |

どれも積み上げ先の `Changes` を最後に受けるので、`noChange()` から `|>` で 1 行 1 列に書ける。

- **`setIfSome` と `setOrNull` を間違えない**。SELECT の行型は NULL 可の列を `Option[a]` で持つ。それを `setIfSome` に渡すと型は通るが、NULL が「変えない」になる。行の値を書き戻すなら `setOrNull`
- **空なら DB に出さず 0 を返す**。`SET updated_at = now(), {changes}` のように固定の代入と並べても壊れない。「行が無い」も 0 なので、区別したければ先に `one` で読む
- 同じ列を 2 回代入したら後の物だけ出す。`rawSet` と `.q` に書いた固定の代入は畳まないので、重ねると PG がエラーにする
- `Changes[t]` は `-> exec` の UPDATE で、UPDATE 直後のテーブル `t` にだけ置ける。それ以外は生成時にエラー。RETURNING 付きは v2

列の型は `Col[UsersTable, String, NotNull]` のように、テーブル・Flix の型・NULL 可否の 3 つを持つ。DDL の `NOT NULL` を生成器が写す。値は `Fragment.value(x)` で同じ型の項にする。

```flix
use Fragment.{===, >>};   // ファイルの先頭か mod の先頭に 1 回

UsersTable.id() === Fragment.value(3i64)           // (id = $1)
UsersTable.deletedAt() >> UsersTable.createdAt()   // (deleted_at > created_at)。値は積まない
Fragment.isNotNull(UsersTable.email())             // email は NULL 可なので書ける
Fragment.isNotNull(UsersTable.name())              // 型エラー。name は NOT NULL
UsersTable.id() === Fragment.value("3")            // 型エラー。Int64 と String
PostsTable.views() >> PostsTable.title()           // 型エラー。Int32 と String
PostsTable.userId() === UsersTable.id()            // 型エラー。テーブルが違う（JOIN 条件は .q に書く）
Fragment.value(1) === UsersTable.id()              // 型エラー。左辺は列
```

`>` `<` `==` などは Flix の組み込みで定義し直せないので、`=` `<>` は Slick と同じ `===` `=!=`、順序は文字を重ねた綴りにしている。`>>` は Prelude の関数合成と同じ綴りだが、`use Fragment.{>>}` を書いたスコープだけ列比較になる。
生 SQL を断片に入れたいときは `Fragment.rawPred(sql)` で、呼ぶ側に `RawSql` エフェクトが付く（§5 と同じ標識。生成された関数の中で許可されることはなく、呼び出し側の型に残る）。

## 5. 生 SQL で書く（逃げ道）

`.q` に書けない文（CTE、DDL、`SET`、`EXPLAIN`）や、その場限りの SQL は `Sql.fetch` / `Sql.execute` に文字列で渡せる。
生の文字列を渡す関数には `RawSql` エフェクトが付き、それを呼ぶ関数の型にも伝わる。生 SQL に依存する箇所が型シグネチャから列挙でき、境界で `RawSql.runWithAllow` を書いた所が監査点になる。`.q` から生成した関数には付かない（生成器が検査した SQL なので、生成コードが自分で許可している）。

```flix
use SqlValue.SqlValue

def renameUser(user: { id = Int64, name = String }): Int32 \ DbWrite + RawSql =
    Sql.execute("UPDATE users SET name = $1 WHERE id = $2", List#{SqlValue.Str(user#name), SqlValue.Int64(user#id)})
```

結果は `Row` の列で返る。型を付けて受けるには `Decoder` を `forA` で組み、`Sql.fetchAs` に渡す。SELECT 句は `Decoder.selectClause` で組めるので、列名を書くのはデコーダの 1 回だけになる。

```flix
pub type alias User = { id = Int64, name = String, email = Option[String] }

def userDecoder(): Decoder[User] =
    forA (
        id <- Decoder.int64("id");
        name <- Decoder.str("name");
        email <- Decoder.opt(Decoder.str("email"))      // NULL を None に
    ) yield { id = id, name = name, email = email }

def findUserByEmail(email: String): Option[User] \ DbRead + RawSql =
    Sql.fetchOneAs(userDecoder(), "SELECT ${Decoder.selectClause(userDecoder())} FROM users WHERE email = $1", List#{SqlValue.Str(email)})
    // => SELECT id, name, email FROM users WHERE email = $1

def countPosts(): Int64 \ DbRead + RawSql =
    let count = Decoder.selectExpr("count(*)::bigint", Decoder.int64("n"));   // count(*)::bigint AS n
    Sql.fetchOneAs(count, "SELECT ${Decoder.selectClause(count)} FROM posts", Nil) |> Option.getWithDefault(0i64)
```

| 関数 | 返す物 | 効果 |
|---|---|---|
| `Sql.fetch` / `fetchOne` | `List[Row]` / `Option[Row]` | `DbRead + RawSql` |
| `Sql.fetchAs` / `fetchOneAs` | デコードした値 | `DbRead + RawSql` |
| `Sql.execute` | 影響行数 `Int32` | `DbWrite + RawSql` |
| `Sql.executeReturningAs` / `executeReturningOneAs` | RETURNING の行をデコードした値 | `DbWrite + RawSql` |

デコードに失敗すると `DbErr.decodeError` が上がる。列が無い、型が違う、NULL 不可の列が NULL、JSON として読めない、の 4 種類で、静かに壊れない。

値の型は `SqlValue` の 1 つの enum で、行きも帰りも同じ:

```
Null  Bool  Int32  Int64  Float64  Decimal(BigDecimal)  Str  Bytes
Timestamp(epoch µs, UTC)  Date(epoch day)  Uuid  Json  Int64Array  StrArray
```

実行するには接続を開いて被せる。生 SQL を使う関数を呼ぶ境界では `RawSql.runWithAllow` で許可する。

```flix
def main(): Unit \ IO =
    let config = { url = "jdbc:postgresql://127.0.0.1:5432/sqlfx", user = "flix", password = "flix" };
    let found = DbError.runWithFailure(() -> RawSql.runWithAllow(() ->
        Jdbc.withConnection(config, _ -> findUserByEmail("alice@example.com"))));
    match found {
        case Ok(user) => println("${Option.map(u -> u#name, user)}")
        case Err(failure) => println("db failed: ${failure}")
    }
```

`RawSql` は防止のための物ではなく、責任の所在を示す物。書ける SQL は変わらない。生 SQL を使う関数は効果を明示して書く（書き忘れると純粋な関数と見なされ、本体で `Sql.*` を呼んだ時点でコンパイルエラーになる）。

### 日時と JSON

列の値は生の `Int64` や `String` でなく、意味を持つ型で出てくる。`TIMESTAMPTZ` は `Timestamp`（UTC の瞬間）、`DATE` は `Date`（暦日）、`UUID` は `Uuid`、`JSON` / `JSONB` は標準ライブラリの `Util.Json.Json`。
中身は `SqlValue` のままなので、JDBC とテストハンドラは変わらない。

```flix
Timestamp.now() |> Timestamp.plus(Time.Duration.days(7))              // 1 週間後。now は Clock
PostsTable.publishedAt() <<= Fragment.value(Timestamp.now())          // 断片 DSL でそのまま比較
Timestamp.format(Format.iso8601Minute(), row#createdAt)               // "2026-09-06 10:00"。\ TimeZone
Timestamp.toCivil(row#createdAt)#date                                 // その地域の暦日。\ TimeZone
Date.fromYmd({ year = 2026, month = 2, day = 30 })                    // None。存在しない日は作れない
Timestamp.at("2026-09-06T01:00:00Z")                                  // リテラル用。形が違えば bug!

run { render(posts) } with TimeZone.runWith(zone)                     // 境界で 1 回。zone は Zone.fromName("Asia/Tokyo") で作る
run { Blog.publishDue() } with TimeTest.runFrozen({ now = "2026-09-06T00:00:00Z", zone = Zone.utc() })   // テストで時刻とゾーンを止める
```

- **瞬間と暦日は別の型**。`Timestamp` 同士の比較と算術は純粋。`Date` に落とす所だけ `TimeZone` が付く
- **ゾーンは effect で差し込む**。表示の関数は引数にゾーンを持たず、型に `\ TimeZone` が出る。システム既定のゾーンを返す関数は無いので、`TimeZone.runWith` を書いた所で必ず明示的に決まる
- **書式は `Format.pattern("yyyy-MM-dd HH:mm")`**。受ける文字は `yyyy M MM MMMM d dd EEEE HH mm ss SSS zzz xxx` と `'...'` だけで、`YYYY` や `hh` は `bug!` で止まる。中身はトークンの List なので直接並べてもよい。ISO 8601 は `toIso8601` / `fromIso8601`
- JSON は `Decoder.json`（`Util.Json.Json`）か `Decoder.jsonAs`（`FromJson` のある型へ）。書くときは `ToJson` で `Json.Json` にして渡す。読めない JSON は `DecodeError.InvalidJson`
- `Uuid.random()` は `NonDet`、`Uuid.fromString` は形を検証して `Option`

`Timestamp` / `Date` / `Zone` / `TimeZone` / `Format` / `TimeTest` は `src/Time/`、`Uuid` は `src/Uuid/` にあり、DB の層に依存しない（切り出せる）。

## 6. エラーの扱い

DB のエラーは 2 つのエフェクト。どちらの op も戻らない（`Void`）。

```
TransientDbErr   deadlock / timeout / connectionLost         再実行で直りうる → withRetry
DbErr            uniqueViolation / foreignKeyViolation /      直らない
                 checkViolation / notNullViolation /
                 schemaMismatch / decodeError / retryExhausted / other
```

制約違反は制約名付き（`notNullViolation` だけ列名）。制約名は pgjdbc の `ServerErrorMessage` から取るので、PG のロケールに依存しない。

### 入力の制約は DDL に書く

長さや文字種のような入力の制約は、DB の `CHECK` に書く。全経路（バッチ、手作業、別のアプリ）を守れるのは DB の制約だけで、
言語側の検証は自分のコードの経路しか守らない。言語側にも書くのは、フォームに複数のエラーをまとめて返すといった UX のためで、防御線ではない。

- 分岐したい制約には `CONSTRAINT name` で名前を付ける。名前が無いと PostgreSQL が付けた名前で返り、推測になる
- `CHECK` で書けない条件は、FK で表せる形に正規化する → トリガ → 監査クエリで後追い、の順で寄せる
- `NOT NULL` は生成された関数の引数の型が守る。`notNullViolation` が出るのは、生 SQL か UPDATE で NULL を書いたとき

既存のデータがある表に `CHECK` を足すときは、`ADD CONSTRAINT ... NOT VALID` で足し（新規の書き込みだけ検査が効く）、
違反している行を数えて直してから `VALIDATE CONSTRAINT` する。一発の `ADD CONSTRAINT` は 1 行でも違反があれば失敗する。

```sql
ALTER TABLE users ADD CONSTRAINT users_name_length CHECK (length(name) <= 50) NOT VALID;
-- SELECT count(*) FROM users WHERE NOT (length(name) <= 50) で数えて直す
ALTER TABLE users VALIDATE CONSTRAINT users_name_length;
```

### 制約違反を業務エラーに翻訳する

生成器は DDL の名前付き制約をテーブルごとの enum にし、翻訳しながら書き込む `onConstraint` を出す。

```flix
// 生成物（src/Gen/Tables.flix）
mod UsersTable {
    pub enum Constraint { case EmailKey /* users_email_key */, case NameLength /* users_name_length */ }
    pub def raiseConstraint(constraint: Constraint): a \ DbErr                         // 翻訳しない case で元の DbErr に戻す
    pub def onConstraint(translate: Constraint -> a \ ef1, thunk: Unit -> a \ ef2): a \ ef1 + ef2 + {TransientDbErr, DbErr}
}
```

翻訳は enum 上の `match` で書く。case が足りなければコンパイルエラーなので、migration で制約を足して再生成すると、
そのテーブルに書く箇所すべてが新しい case を書くまで通らない。業務エラーも `DbErr` と同じくエフェクトにすると、途中の関数は戻り値を包まず、境界で 1 回ハンドリングするだけになる。

```flix
pub eff RegisterErr {
    def emailTaken(email: String): Void
    def nameTooLong(): Void
}

pub def registerUser(user: NewUser): Int64 \ DbWrite + RegisterErr =
    UsersTable.onConstraint(translateUserConstraint(user), () ->
        UsersQueries.insertUser({ name = user#name, email = user#email, role = "member" }) |> expectRow)

def translateUserConstraint(user: NewUser, constraint: UsersTable.Constraint): a \ RegisterErr = match constraint {
    case UsersTable.Constraint.EmailKey => RegisterErr.emailTaken(user#email)
    case UsersTable.Constraint.NameLength => RegisterErr.nameTooLong()
}
```

enum に無い名前の違反（本番に手で足した制約など）と、制約違反以外の DB エラーは翻訳されず、`DbErr` のまま上へ流れる。
`onConstraint` は `Tx.withTx` の **外** で呼ぶ。PG は制約違反で Tx を abort するので、内側で翻訳して値を返すと `withTx` が COMMIT を発行してしまう。

境界（main / HTTP ハンドラ / テスト）で 1 層の `Result` にするには `DbError.runWithFailure`。業務エラーは `run … with handler RegisterErr { … }` で受ける。

## 7. migrate

`migrations/*.sql` を DB に当てる。`gen` と同じファイルを読むが、パーサは通さず JDBC にそのまま渡す（関数やトリガも当たる）。
前進のみ。適用済みは `sqlfx_migrations(version, checksum, applied_at, execution_ms, applied_by)` に記録する。

```
$ SQLFX_DSN=jdbc:postgresql://127.0.0.1:5432/blog SQLFX_USER=flix SQLFX_PASSWORD=flix \
    bin/flix run -- migrate migrations/            # 未適用を番号順に当てる
    bin/flix run -- migrate --check migrations/    # 未適用・不一致・欠落があれば exit 1（CI と起動前）
    bin/flix run -- migrate --status migrations/   # 一覧
$ bin/flix run -- migrate new migrations/ add_note   # 次の番号で 004_add_note.sql を作る（DB は使わない）
```

- ファイル名は `NNN_name.sql`（3 桁以上のゼロ埋め）。文字列順で並べても番号順になる形に固定する。記録に無いファイルは番号が小さくても当てる（ブランチのマージで割り込む）
- 同じ番号のファイルが 2 つあれば `duplicateNumber` で止まる（マージで両方が 004 になった時）。どちらかを `migrate new` で振り直す
- 1 ファイル 1 Tx。全文と記録の INSERT を同じ Tx に入れるので「当たったのに記録が無い」は起きない。途中で失敗したらそのファイルと後続は未適用のまま
- 先頭行が `-- sqlfx:no-transaction` のファイルは Tx 無し（`CREATE INDEX CONCURRENTLY` 用）。1 文だけにし、`IF NOT EXISTS` で冪等に書く
- 適用済みのファイルが書き換わっていれば `checksumMismatch` で止まる（CRLF、行末の空白、末尾の空行は無視）。記録にあるがファイルが無ければ `missingFile`
- 専用の接続を 1 本開き、`SET lock_timeout`（既定 10 秒）と `pg_advisory_lock` を取ってから当てる。複数台が同時に走っても 1 つずつ。プールの接続は使わない

アプリからは `Migrate.apply(Migrate.defaultConfig(config), "migrations")` と `Migrate.check(conn, "migrations")`。推奨は「デプロイの手順で apply、起動時に check」。
失敗は `DbErr` と `MigrateErr`（`checksumMismatch` / `missingFile` / `invalidFileName` / `duplicateNumber` / `pending`）で型に出る。境界では `Migrate.runWithResult`。

## 8. Tx と再実行

```flix
let pool = Pool.open(Pool.defaultConfig(config));   // 起動時に 1 回。終了時に Pool.close

Retry.withRetry(3, () ->                            // Transient なら thunk を最初から呼び直す（接続も借り直す）
    Pool.withConnection(pool, conn ->               // プールから借りて、必ず返す
        UsersTable.onConstraint(translate, () ->    // 制約違反の翻訳は Tx の外
            Tx.withTx(conn, () ->                   // BEGIN / COMMIT。失敗なら ROLLBACK して再送出
                Blog.removeUser(1i64)))))
```

`Pool` は HikariCP を包んだ物。接続数の上限を超えた借り出しは `borrowTimeoutMs` 待って `TransientDbErr.timeout` になる。
CLI やテストのように 1 回だけ開くなら `Jdbc.withConnection(config, conn -> ...)`（毎回接続する）。
`withRetry` を `withConnection` の外に置くのは、`connectionLost` した接続で再試行しても無駄だから。

```
   withRetry ─┬─ attempt 1: withTx ─ BEGIN ─ DELETE ─ UPDATE ─ deadlock ─ ROLLBACK
              ├─ attempt 2: withTx ─ BEGIN ─ DELETE ─ UPDATE ─ COMMIT ─▶ 値
              └─ 枯渇したら DbErr.retryExhausted
```

再実行は Tx 単位。PG はデッドロック後に Tx 全体が aborted になるので、文単位の再実行は意味を持たない。
COMMIT で初めて出るエラー（遅延制約など）も翻訳し、接続は autocommit に戻る。ネストは v0 では未対応。

### Web から使うときの前提

- 縁（全ハンドラ共通）で `DbError.runWithFailure`（→ 500 / 503）、`Retry.withRetry`、`Pool.withConnection`、`RawSql.runWithAllow` を重ね、ハンドラごとに書くのは検証と Tx の範囲と制約違反の翻訳
- 業務エラー（`RegisterErr` のようなエフェクト）は service 層で翻訳し、controller のハンドラで HTTP のステータスに写す。検証（`Validation`）のエラーと同じ型にまとめる例が `examples/blog/src/BlogForm.flix`
- 発行 SQL と件数の記録は `DbTest.runLogging` を縁に被せる。`statement_timeout` の口は未実装

## 9. テストの書き方

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

## 10. make の一覧とディレクトリ

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
