# Flix DBライブラリ 設計概要

長い設計検討の到達点をまとめる。名前は仮に `sqlfx` とせず「本ライブラリ」と書く。
対象は PostgreSQL・JVM(JDBC)・Flix。

---

## 1. 設計思想(なぜ作るか)

ORM批判(隠蔽のコスト、実行計画の不可視化、JOIN/サブクエリの捨象)は正当であり、
本ライブラリは Hibernate 型の「隠蔽する ORM」ではない。出発点は sqlc / sqlx と同じ
**「SQL を 1 ミリも抽象しない。型だけ後付けする」**。その上で、sqlc/sqlx が
「規約でやってくれ」と投げている領域 — SQL 文の *間* — をエフェクトで拾う。

- SQL 文の中: 手書き SQL + 実 DB 検証(sqlx 方式)で守る
- SQL 文の間: DB 境界の可視化・N+1・エラーの捌き方・Tx・テストを型とエフェクトで守る

一言で: **「sqlc はクエリに型を付けた。本ライブラリはクエリの間に型を付ける」**。

貫く原則:
- 暗黙の lazy loading は存在しない。関係取得は常に明示操作
- 生成 SQL は予測可能で EXPLAIN で読める形を保つ(賢い最適化は悪。最適化の主導権は DB プランナにある)
- 問題は早い段で捕まえるほど安く、遅い段ほど「派手に・即座に」失敗させる(静かな半壊が最悪)

## 2. 全体構成(層)

```
migrations/*.sql   ← スキーマの唯一の真実(手書き・Flyway互換命名 V001__xxx.sql)
queries/*.q        ← クエリの唯一の真実(手書き・小さな外部DSL)
      ↓ 生成器(スキーマ解決 + PREPARE検証 + コード出力 + LSP)
生成コード: 型付き関数(\ SqlRead / SqlWrite)+ preloader + デコーダ
      ↓
アプリ: エフェクト境界・エラー2分類・ハンドラテスト・クエリ数/EXPLAIN検証
```

パッケージは 3 層に分離し、下だけでも使えるようにする(採用の入口を増やす):

- 層0: 生SQL + 型付き結果 + エフェクトのみ(SQL手書き派向け。DSL嫌いはここで完結)
- 層1: .q ファイル + codegen + 断片DSL
- 層2: 関係取得(preload / JSON集約)・マイグレーション統合

## 3. .q ファイル(クエリ定義の外部DSL)

コメントアノテーション(sqlc 方式)は採らない。外側は本物の文法、中身は素の SQL。

```
// users.q
query findUser(id: Int64) -> one {
    SELECT id, name, role FROM users WHERE id = :id
}

query searchUsers(limit: Int64) -> many
    with filter: Pred[users], order: Order[users]
{
    SELECT id, name FROM users
    WHERE deleted_at IS NULL AND {filter}
    {order}
    LIMIT :limit
}

query postsByUsers(ids: List[Int64]) -> many keyed(user_id) {
    SELECT id, user_id, title FROM posts WHERE user_id = ANY(:ids)
}
```

設計判断:
- `query 名前(引数) -> 形` はパーサが構文検査する第一級構造(書き忘れの黙殺が起きない)
- パラメータは `:name` の名前参照。宣言と使用の対応をパース時に検査
- 戻り形 `one / many / exec` が `Option[Row] / List[Row] / Int32` に対応
- `keyed(col)` から preloader を生成
- 動的部分だけ `{slot}` + `with` 節で型宣言(断片DSL、下記 §5)
- SELECT 文からは `\ SqlRead`、UPDATE/INSERT/DELETE からは `\ SqlWrite` を生成器が自動付与
- 機械置換(`:id`→`$1`、`{filter}`→`TRUE`)で完全な SQL に戻る = EXPLAIN・DBAレビューと往復可能

検証は 3 段: 生成時(migrations から組んだスキーマで名前・型解決)/
CI時(実 PostgreSQL に全クエリ PREPARE。実行なし。sqlx 相当)/
起動時(スキーマハッシュ照合 → 不一致は Fatal)。

LSP はロードマップに含める(パーサ=LSP の土台。ブロック内は SQL としてカラム補完)。

## 4. エフェクト体系

### 4.1 DB境界

```flix
pub eff SqlRead  { def fetch(sql: String, params: List[SqlValue]): List[Row] }
pub eff SqlWrite { def execute(sql: String, params: List[SqlValue]): Int32 }
```

op 名は sqlx の語（`fetch` / `execute`）に合わせる。`query` / `exec` は Flix の予約語・慣用と
ぶつかるので使わない。プレースホルダに渡す値と行のセルの値は同じ `SqlValue` 1 つで表す（§7）。

読み書きを分離する: 「このユースケースは読むだけ」が型に出る。リードレプリカ
振り分け・CQRS 的規律・「GET が書いている」検出がハンドラと型で得られる。

### 4.2 エラーの2分類(再実行で直るかで分割し、捌く層を変える)

```flix
pub eff TransientDbErr {         // 一時障害。Tx 境界ごと再実行すれば回復しうる
    def deadlock(): Void
    def timeout(ms: Int32): Void
    def connectionLost(msg: String): Void
}
pub eff DbErr {                  // 再実行しても直らない DB エラー
    def uniqueViolation(constraint: String): Void
    def foreignKeyViolation(constraint: String): Void
    def checkViolation(constraint: String): Void
    def notNullViolation(column: String): Void
    def schemaMismatch(detail: String): Void
    def decodeError(column: String, detail: String): Void
    def retryExhausted(last: String): Void
    def other(detail: String): Void
}
pub type alias Db = { SqlRead, SqlWrite, TransientDbErr, DbErr }
```

- 捌く場所: Transient=インフラ層(withRetry。リトライ枯渇は DbErr へ昇格)/ DbErr=main(ログ+アラート+終了)。
  制約違反で分岐したいアプリは `DbErr` にハンドラを被せて自分のエフェクトへ読み替える
- 「notFound」のような業務の判断はこのライブラリのエフェクトにしない(0 行は正常な結果として `Option` で返す)。
  本ライブラリは純粋な DB ライブラリで、業務エラーはアプリが自分のエフェクトで持つ
- シグネチャから「どのエラーが処理済みか」が常に読める。捌き忘れ・握りつぶしが型で見える
- 文脈依存の再分類(冪等リトライ中の uniqueViolation は成功扱い等)は reclassify ハンドラで一級サポート(v2)
- 両分類とも op は `Void`(再開不能)。Transient を「その場から再開」にしないのは、再開先が
  `fetch` の呼び出し元で返す `List[Row]` が無く、PG はデッドロック後に Tx 全体が aborted に
  なるので文単位の再実行が Tx 内では不正だから。`withRetry` は **thunk(= withTx 単位)を
  呼び直す**形で実装する
- `Db` のエフェクト集合 alias は Flix 0.75.3 で書ける(docs/spikes.md (a))

### 4.3 トランザクション

`withTx` は接続を固定したハンドラを内側に被せる実装。方針:
- ネストはセーブポイントに落とす(または型エラー。初期実装で決める)
- Tx 内の spawn は禁止。Flix は制御エフェクトをスレッド越しに再開できないので、`spawn` 本体に
  `SqlRead` を残せない=言語側で禁止済み(docs/spikes.md (b) で実測。本体側は何もしない)
- 読み取り専用 Tx・分離レベルはオプションで明示
- Transient / DbErr のどちらが飛んでも ROLLBACK して再送出

## 5. 断片DSL(動的クエリ)

クエリ全体の内部DSL化はしない(表現力の壁・実装量・SQL手書き派との摩擦)。
実行時に形が決まる部分だけを型付きの値として合成する:

```flix
searchUsers(50,
    filter = and(U.deletedAt().isNull(),
                 when(req.name != "", U.name().like(req.name))),
    order  = by(req.sortKey))
```

- `Col[row, a, n]` はファントム型付きカラム値(codegen が吐く)。文字列カラム名は書かない。`n` は `NotNull` / `Nullable` で、`isNull` は `Nullable` の列にだけ書ける
- 比較は `=== =!= << <<= >> >>=`。左は列、右は列か `Fragment.value(x)`。`>` などは Flix の組み込みで定義し直せない（`docs/spikes.md`）
- 実装では `and` / `or` / `not` が Flix の予約語なので `both` / `either` / `negate`。`by` は `asc` / `desc` / `then`（`docs/layer1.md`）
- `Pred[users]` 型で「どのテーブルの列を参照できる断片か」を宣言
- 値は必ず `EParam` ノード → プレースホルダへ。識別子は Col 経由のみ =
  **SQLインジェクションが構造的に不可能**(動的識別子は自然と許可リスト化)
- render は (SQL文字列, パラメータ列) のペアを返す再帰で順序整合を構造保証。括弧は全付け
- 生SQL エスケープハッチは `RawSql` エフェクトで標識化(監査箇所が型から列挙できる)。`Sql.fetch` / `Sql.execute` に文字列を渡す入口にも付け、生成コードだけが自分で許可する

## 6. 関係取得(N+1対策)

暗黙のロードは存在しない。2 方式を明示的に使い分ける:

1. **preload(IN句バッチ)**: `.q` の `keyed` から生成。
   `users |> withPosts` で行多相レコードに `posts` フィールドが**型として**生える。
   ロード忘れ = コンパイルエラー(Ecto の実行時エラーより強い)。常に 2 クエリ固定
2. **JSON集約(1クエリ)**: `json_agg` サブクエリを `:json` アノテーションで宣言、
   ネストしたレコードへデコード。金額など精度が要る列は `::text` 経由の指定を用意

belongs-to は素直に JOIN を書く(行が増えないので)。has-many を複数 JOIN する
カルテシアン積は preload/JSON へ誘導。

## 7. JDBCハンドラ(腐敗防止層)

構成: compile(純粋)→ Sql エフェクト → jdbcHandler → java.sql.*

- ResultSet は**即時 materialize** して不変 Row へ写経、接続から切り離す
- 型対応の四天王をハンドラ内に封印: wasNull / DECIMAL は BigDecimal 経由 /
  TIMESTAMP は OffsetDateTime 指定 / pg の OTHER(jsonb, uuid, enum, 配列)
- 値は行き(プレースホルダ)も帰り(セル)も **1 つの enum `SqlValue`** で表す。型対応表を
  1 つにするため。`Eq` を derive できるように Java 型を payload に持たず、Timestamp は
  epoch マイクロ秒(UTC)の `Int64`、Decimal は Flix の `BigDecimal` で持ち、`OffsetDateTime` /
  `java.math.BigDecimal` への変換は JDBC ハンドラの内側に閉じる。`ANY(:ids)` 用に配列 case も持つ
- Row 実装は 配列 + 共有列名インデックス。デコーダは compile 時に添字解決。
  デコード失敗は `DbErr.decodeError`(列名と理由)。層0 の API 詳細は
  [layer0.md](layer0.md)
- 大量データは `streamQuery`(fetchSize + 1行ずつ継続呼び出し)を別操作で
- SQLException → sqlstate で 2 分類へ翻訳("23505"→uniqueViolation, "40001"→deadlock,
  "42703"→schemaMismatch 等)
- ハンドラ規約: 継続 k は必ず 1 回だけ呼ぶ
- ハンドラは 3 種を標準装備: 本番(JDBC+プール)/ テスト(固定データ・インメモリ)/
  計測(クエリログ・カウント)。ログ層・キャッシュ層は Sql を包む中間ハンドラとして合成

## 8. マイグレーション(同梱)

適用系も同梱する(数百行)。Flyway とはファイル形式互換 + 「読むだけモード」で共存可。

- 履歴テーブル(version + checksum)、昇順適用、歯抜け検出、改竄検出
- PG の DDL トランザクションで applyOne を包む(半分適用が存在しない)。
  `-- sqlfx: no-tx` 注釈で CREATE INDEX CONCURRENTLY 等を非Tx適用
- `migrate --dry` の目玉: 机上でスキーマを進め、**壊れる .q クエリを適用前に列挙**
  (.q 検証器の再利用)+ DDL 危険度警告(ロック・全行書き換えの見積もり)
- 起動時にスキーマハッシュ照合 → 不一致は `DbErr.schemaMismatch`
- plan / analyzeImpact は純粋関数(テストは DB なし)

問題検知の防衛線(早いほど安く、遅いほど派手に):
パース時 → codegen時(机上) → CI(実DBへ全適用+全PREPARE) → 適用時(checksum+警告+Tx)
→ 起動時(ハッシュ) → 実行時(decodeError→DbErr)。同じ部品を違うタイミングで再実行する構造。

## 9. テスト戦略(5層)

| 層 | 対象 | DB | 例 |
|---|---|---|---|
| 1 | 純粋ロジック | 不要 | デコード後の加工、plan、analyzeImpact |
| 2 | ハンドラモック | 不要 | 固定 Row を返して usecase を検証 |
| 3 | 観測アサーション | 不要 | **クエリ数の回帰テスト**(上限で表明: assertLe)、発行SQL列、compile のスナップショット |
| 3.5 | PREPARE / EXPLAIN | CI の PG | 全 .q を PREPARE。EXPLAIN で seq scan 警告・コスト回帰検出(将来) |
| 4 | インメモリDB | 不要 | INSERT→SELECT の整合(深追いせず 5 へ) |
| 5 | 実DB(Testcontainers) | 要 | PG 固有挙動・マイグレーション実適用。少数precision |

方針: `\ SqlRead/SqlWrite` を持つ関数は薄く、ロジックは純粋関数へ。
クエリ数テストは実装詳細への結合を避け、上限 + O(1)/O(n) のプロパティ形式で書く。

## 10. 実装ロードマップ(段階導入)

```
v0(層0):  SqlRead/SqlWrite + エラー2分類 + jdbcHandler + 生SQL型付き実行
          + テストハンドラ3種   ← ここだけで思想の核は全部動く
v1(層1):  .q パーサ + codegen(スキーマ解決・PREPARE検証・エフェクト自動付与)
          + 断片DSL(Pred/Order 最小)
v2(層2):  keyed preloader + JSON集約 + withTx 完成
v3:       マイグレーション同梱(plan/dry/impact) + 起動時ハッシュ
v4:       LSP + EXPLAIN テスト統合 + ドキュメント
```

スパイクで検証すべき技術リスクと、そのタイミング:
- v0 の前: (a) エフェクト集合の `type alias` が書けるか (b) `spawn` 本体に自作エフェクトを
  置けるか(置けなければ Tx 内並行は言語側で禁止済み) (c) Maven 依存の `org.postgresql.Driver`
  を直接ロードして接続できるか
- v0 の完了条件に含める: 多層ハンドラ(ログ → 計測 → JDBC)の実行性能の計測
- v2 の前: 行多相 + trait 越しの型推論とエラーメッセージ(preloader がフィールドを型に生やす形)

## 11. 競合との位置づけ(要約)

- sqlc/sqlx: SQL の中の検証は同格〜(PREPARE導入で)同等。動的クエリ・N+1・
  エラー層規律・DB境界可視性・テストで上回る。「sqlc の後継」ポジション
- Kysely/jOOQ: フル内部DSLとは戦わない。動的クエリの極端なケースは譲る
- Ecto: preload 忘れが実行時エラー vs 本ライブラリはコンパイルエラー
- 弱点は変わらずエコシステム。sqlc 互換の書き味と SQL ファイル資産の持ち込みが梯子

## 12. 設計上の未決事項(実装時に決める)

- Tx ネストの扱い(セーブポイント vs 型エラー)。v0 では型エラー固定
- 断片DSLの演算子セット。列と値・列と列・isNull までは入れた。式（算術・関数）は未着手
- `Pred[users]` の row 型の付け方(codegen が吐くマーカー型の設計)
- streamQuery の each に許すエフェクトの範囲
- reclassify ハンドラの API 形状
- .q の with 節に Order 以外(limit句スロット等)をどこまで許すか
