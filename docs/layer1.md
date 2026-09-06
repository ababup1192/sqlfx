# 層1: `.q` → 型付き関数（実装メモ）

design.md §3 / §5 の実装。モジュールは `src/Q/` にトップレベルで平らに置く。

```
SqlType     .q の型名 / PG の型名 / SqlValue の case / 生成する Flix の型 の対応表
QueryDef    .q の AST（Query / Param / Slot / Segment / Shape / SlotKind）
QParser     .q のパーサ。エラーは ParseError（文字位置つき）
QRender     AST → 完全な SQL（`:id` → `$1`、`{filter}` → `TRUE`、`{order}` → 空）
Schema      机上のスキーマ（テーブル名 → 列の名前・型・NULL 可否）
DdlParser   migrations の DDL → Schema。読めない文は警告
SqlTokens   SQL の字句（QResolve が使う）
QResolve    SELECT の FROM / JOIN / リストを Schema に当てて結果の列を決める
Fragment    断片 DSL（Col / Pred / Order と render）、RawSql エフェクト
Codegen     Resolved → Flix ソース
src/Main.flix  `bin/flix run -- gen <migrations> <queries> <out>`
```

## `.q` の文法

```
// 行コメント
query 名前(引数: 型, ...) -> one | many | exec [keyed(列)] [with slot: Pred[テーブル] | Order[テーブル], ...] {
    素の SQL。:name で引数、{slot} で断片
}
```

- 型名は Flix の綴り: `Bool Int32 Int64 Float64 BigDecimal String Bytes Timestamp Date Uuid Json List[Int64] List[String]`
- `:name` は宣言に無いとエラー、宣言して使わないのもエラー。`{slot}` も同じ。`'...'` の中と `::text` は触らない
- `keyed` は `many` だけ。同じ名前の query は 1 ファイルに 1 つ
- `one` / `many` は SELECT か `RETURNING` 付きの書き込み、`exec` は `RETURNING` 無しの書き込み（v1 では CTE は未対応）
- 本文の `--` から行末はコメントとして落ちる
- query 名・引数名・slot 名は Flix の識別子になるので、予約語と生成コードの内部名（`sql` / `params` / `paramsN` / `xxxSql` / `sourceHash`）は生成時にエラー

## 読む DDL（DdlParser）

CREATE TABLE / DROP TABLE（カンマ区切りも）/ ALTER TABLE の ADD|DROP [COLUMN] [IF [NOT] EXISTS]・ALTER COLUMN SET|DROP NOT NULL・TYPE・RENAME COLUMN。
制約の追加削除と CREATE INDEX は無視、それ以外の文は警告。`NUMERIC(10, 2)` のような長さ指定は落として型名だけ見る。

## 解決の規則（QResolve）

- FROM / JOIN / UPDATE / INSERT INTO / DELETE FROM の後ろをテーブルとして読む。`AS` 付き・無しの alias、カンマ区切りの FROM も追う。サブクエリは飛ばす
- SELECT リストは `*` / `t.*` / `col` / `t.col` / `col AS name` / `col::type` / `expr::type AS name` だけ。
  式には型を付けない（`count(*) AS n` はエラー、`count(*)::bigint AS n` と書く。式の列は NULL 可）
- LEFT / RIGHT / FULL [OUTER] JOIN で外側になる方の列は NULL 可になる。修飾無しの列が 2 テーブルにあればエラー
- `RETURNING` の後ろは SELECT リストと同じ規則で解決する
- `keyed(col)` は結果の列に無いとエラー、slot のテーブルは FROM に無いとエラー

## 生成物の形

```flix
pub type alias FindUserRow = { id = Int64, email = Option[String] }
def findUserDecoder(): Decoder[FindUserRow] = forA (id <- Decoder.int64("id"); email <- Decoder.opt(Decoder.str("email"))) yield { id = id, email = email }
pub def findUser(id: Int64): Option[FindUserRow] \ {SqlRead, DbErr} = ...
pub def insertUser(name: String): Option[InsertUserRow] \ {SqlWrite, DbErr} = ...   // INSERT ... RETURNING id
pub def searchUsers(limit: Int64, filter: Fragment.Pred[UsersTable.UsersTable], order: Fragment.Order[UsersTable.UsersTable]): List[SearchUsersRow] \ {SqlRead, DbErr}
pub def renameUser(id: Int64, name: String): Int32 \ SqlWrite
pub def sourceHash(): Int32   // .q の中身のハッシュ。テストで現物と照合する
```

- ファイル `users.q` → `mod UsersQueries`、テーブル `users` → `mod UsersTable`（印の enum と列の `Col`）
- 列名は camelCase（`user_id` → `userId`）、予約語は末尾 `_`
- 引数が 2 つ以上の query は 1 つのレコードで受ける（`insertUser({ name = "a", email = "a@x", role = "member" })`）。同じ型が並んでも取り違えない
- slot は宣言順に引数の後ろへ。Pred は `Fragment.appendPred` で `$n` を続き番号で振り、Order は `Fragment.renderOrder`

## 断片 DSL

```flix
Fragment.both(Fragment.isNull(UsersTable.deletedAt()),
              Fragment.when(prefix != "", Fragment.like(UsersTable.name(), prefix + "%")))
Fragment.then(Fragment.asc(UsersTable.name()), Fragment.desc(UsersTable.id()))
```

- 述語: `eq ne lt le gt ge like isNull isNotNull inList both either negate when all any always`。`always()` は TRUE で `both` はそれを消す、`inList` の空は FALSE
- 並び順: `asc desc then unordered`、`unordered()` は ORDER BY を出さない
- render は括弧全付け。値は必ず `$n` になり、識別子は `Col` からしか来ない
- 生 SQL は `Fragment.rawPred(sql)` で、呼ぶ側に `RawSql` が付く。境界で `RawSql.runWithAllow`

## デモ（examples/blog）

flix.toml を持つ独立した Flix プロジェクト。本体は `make vendor` で `../../src/Db` と `../../src/Q` を `src/flix_db/` に写して使う
（flix.toml の依存は GitHub のリリースしか指せず、`lib/` の .fpkg は flix.toml があると読まれないため）。
`make gen` で `src/Gen/` を作り直し、`make test` が DB 無し → 実 PG の順に回す。生成物が最新かは本体側の `gen --check`（`make gen-check`）と `test/Q/TestGen.flix` で確かめる。生成物の形を決めているのは Codegen なので、デモ側にはこの検査を置かない。
テストは「.q から生成した関数を使う版」（`Blog` / TestGenerated*）と「生 SQL をインラインで書く版」（`BlogRaw` / TestRawSql*）の 2 系統で、同じ筋書きを両方で通す。

## v1 で切った物

- CTE（`WITH`）、サブクエリの列解決、式の型推論
- `keyed` からの preloader 生成（フェーズ 3）。デモでは手で `user_id` で束ねている
- CI の `PREPARE` 検証（フェーズ 2-5）
