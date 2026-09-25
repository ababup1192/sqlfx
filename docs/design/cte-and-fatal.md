# CTE（WITH）を読むジェネレータと、fatal でも接続を返す Tx

sqlfx 0.6.0 に入れる 2 つの改修の設計。コードはまだ無い。実装とテストは Mac mini で行う（5 節）。

- 改修 1: ジェネレータが `WITH` で始まる query を型付けし、`--scope` の検査を CTE の中の文ごとに、今より厳しい規則で効かせる
- 改修 2: `Pool.withLazyTx*` 系が、fatal（`VirtualMachineError`）を含む全部の `Throwable` で接続を返す。fatal は拾った所で接続を evict し、その場で投げ直す（値にしない）

---

## 1. 改修 1: CTE（WITH）

### 1.1 今の仕組みと、WITH が止まる所

`gen` の 1 ファイル分は `Main.flix` の `Gen.renderOne` で、次の順に流れる。

| 段 | module | やっている事 |
|---|---|---|
| 1 | `QParser.parseFile` | `query name(...) -> shape { 本文 }` を読み、本文を `Text` / `ParamRef` / `SlotRef` の断片に切る。`'...'` と `--` コメントだけを知っていて、`/* */` と dollar quote（`$$...$$`）は知らない |
| 2 | `QLint.warnings` | `Option` の引数を `= :p` に置いた所の警告 |
| 3 | `QScope.plan` | `--scope` の検査と注入。**本文全体の語**にカラム名が 1 度でも出れば通す。触る表は本文全体から `FROM / JOIN / INTO / UPDATE` の直後の語で拾う（`USING` とカンマの続きは拾わない） |
| 4 | `QResolve.resolve` | `QRender.toAnnotatedSql` → `SqlTokens.tokenize` の語の並びで、先頭の語から文の種類（`classifyStatement`）、深さ 0 の `FROM / JOIN / INTO / UPDATE` から table source（`collectSources`）、SELECT リストか `RETURNING` の後ろから結果のカラム（`resolveColumnList`）を決める |
| 5 | `Codegen.renderQueriesWith` | `(shape, writes)` で `DbRead` / `DbWrite` と `Sql.fetchAs` / `executeReturningAs` / `execute` を選んで吐く |

`WITH` で止まるのは段 4 の `classifyStatement` で、先頭の語が `SELECT / INSERT / UPDATE / DELETE` 以外なので `UnsupportedStatement(query, "WITH")` になる。仮に通しても、段 4 の `readSource` は `Schema.findTable` に無い名前を `UnknownTable` にするので、CTE の名前を `FROM` に書いた所で止まる。

段 3 は `WITH` でも止まらない。そのうえ、今の WITH の無い query でも次が素通りする事を実測した（`gen` を当てて生成物が出た）。

| 形 | 今の結果 |
|---|---|
| `INSERT INTO entry_contents (...) SELECT project_id, id, ... FROM entries WHERE id = :entryId` | 通る。`project_id` が SELECT リストに出るだけで、`entries` は絞られていない |
| `DELETE FROM users u USING entries e WHERE e.id = :entryId AND ...` | 通る。`USING` の後ろの `entries` を触る表として拾わない |
| `SELECT id FROM entries /* project_id */ WHERE id = :entryId` | 通る。`SqlTokens` が `/* */` を知らず、コメントの中の語を数える |

CTE を入れる時に一番危ない所はここで、1.8 で詰める。

### 1.2 範囲の決め

| 形 | 扱い | 理由 |
|---|---|---|
| 読み取りの CTE（`WITH a AS (SELECT ...) SELECT ... FROM a`） | 入れる | 型付けは既存の SELECT の解決をそのまま使える |
| 書き込みの CTE（`WITH w AS (UPDATE ... RETURNING ...) UPDATE / INSERT / DELETE / SELECT ...`） | 入れる | nextcms の entry-touch を 1 文にするのに要る |
| 複数の CTE（`WITH a AS (...), b AS (...)`）と、後ろの CTE から前の CTE を読む形 | 入れる | fill と touch を並べる形（1.3）に要る。前方参照は PG と同じく `UnknownTable` |
| CTE の中の `RETURNING` | 入れる | 書き込みの CTE を読む唯一の口。`RETURNING` の無い書き込みの CTE は、`FROM` で読んだ時だけエラー（PG も同じく断る） |
| カラム名の並び（`WITH w(a, b) AS (...)`） | 入れる | 位置でカラム名を付け替えるだけ。数が合わなければエラー |
| `MATERIALIZED` / `NOT MATERIALIZED` | 入れる（読み飛ばす） | 型にも scope にも効かない |
| 本文を参照しない CTE | 読み取りなら QLint の警告、書き込みなら何も言わない | PG は参照されない SELECT の CTE を実行しない。書き込みの CTE は参照されなくても実行されるので、touch の形はそれを使う |
| **1 つの query の中で 2 つ以上の文が同じ表を書く** | 断る | PG の文書（7.8.4）のとおり、同じ row を 2 つの文で書き換えると片方しか効かず、どちらが効くかは決まらない。`WITH b AS (UPDATE entries SET version = ...) UPDATE entries SET updated_at = ...` で touch が黙って 0 row になる事を実測した |
| `WITH RECURSIVE` | 断る | 自分を参照する CTE はカラムの型が再帰の両側の合流で決まり、`!` の marker と組み合わせた NULL 可否の規則を新しく決める事になる。nextcms に要る所も無い |
| 入れ子の WITH（CTE の本文や副問い合わせの中の CTE の WITH） | 断る | scope の検査の単位（1.8）を「文の先頭の WITH の CTE と本文」に固定するため |
| CTE の本文が `VALUES` | 断る（今の `UnsupportedStatement` のまま） | `unnest(:a, :b) AS v(...)` で書ける |
| `WITH` を含む query に `Changes` の slot | 断る | 空の `Changes` で生成物が文ごと出さずに 0 を返す（`skipWhenNoChanges`）ため、別の CTE の書き込みまで黙って消える |
| CTE の名前と表の名前が同じ | 断る | PG は `FROM x` を CTE と読むが、書き込みの対象（`UPDATE x`）は常に表を指す。どちらを指すかで scope の検査の答えが変わる |

**WITH の判定。** 語 `WITH` を CTE の始まりと見るのは、次が続く時だけにする。それ以外の `WITH`（`timestamp with time zone`、`unnest(...) WITH ORDINALITY`、`WITH CHECK OPTION`）は普通の語として通す。

```
WITH [RECURSIVE] name AS [NOT] [MATERIALIZED] (
WITH [RECURSIVE] name ( col [, col]* ) AS [NOT] [MATERIALIZED] (
```

入れ子の WITH（`NestedWith`）も、この形が文の先頭以外（CTE の本文の中、括弧の中）に出た時だけ断る。

### 1.3 nextcms で実際に要る形

`queries/entries.q` の書き込みを touch と 1 文にする。touch の絞り込みは `id = ANY(ARRAY(SELECT ...))` の形にする（nextcms の claim の決まりと同じく、planner が semi join を選んで副問い合わせを row ごとに評価し直す形を避ける。`EXPLAIN` で確かめた）。

`upsertContent`（中身を 1 件書く。`ContentEntries.writeContent`）:

```sql
query upsertContent(entryId: String, stage: String, typeId: Int64, data: Json, dataFold: Json, projectId: Int64) -> exec {
    WITH written AS (
        INSERT INTO entry_contents (project_id, entry_id, stage, type_id, data, data_fold)
        VALUES (:projectId, :entryId, :stage, :typeId, :data, :dataFold)
        ON CONFLICT (project_id, entry_id, stage) DO UPDATE
            SET data = EXCLUDED.data, data_fold = EXCLUDED.data_fold, type_id = EXCLUDED.type_id, updated_at = now()
        RETURNING entry_id
    )
    UPDATE entries SET updated_at = now()
    WHERE project_id = :projectId AND deleted_at IS NULL AND id = ANY(ARRAY(SELECT entry_id FROM written))
}
```

`fillMissingField`（最上位のフィールドの fill。埋めた entry id を返す）:

```sql
query fillMissingField(typeId: Int64, path: String, patch: Json, foldKey: String, foldText: String, projectId: Int64) -> many {
    WITH filled AS (
        UPDATE entry_contents
        SET data = data || :patch, data_fold = CASE ... END, updated_at = now()
        WHERE project_id = :projectId AND type_id = :typeId AND NOT jsonb_path_exists(data, :path::jsonpath)
        RETURNING entry_id
    ), touched AS (
        UPDATE entries SET updated_at = now()
        WHERE project_id = :projectId AND deleted_at IS NULL AND id = ANY(ARRAY(SELECT entry_id FROM filled))
    )
    SELECT entry_id FROM filled
}
```

`upsertContents`（入れ子のフィールドの fill。今の `ContentTypes` は row ごとに `upsertContent` を呼んで最後に `touchEntries`）。row ごとの `upsertContent` を上の 1 文に替えると、Tx の中で「entry_contents → entries → entry_contents → entries」と lock を取る順になり、同じ entry を公開する Tx と組み合わせて deadlock する事を実 PG で再現した（今の「全部の upsert → 最後に 1 回 touch」の形では出ない）。一括の 1 文にして、lock の順を「entry_contents を `(entry_id, stage)` の順に全部 → entries」に固定する。

```sql
query upsertContents(entryIds: List[String], stages: List[String], datas: List[String], dataFolds: List[String], typeId: Int64, projectId: Int64) -> many {
    WITH written AS (
        INSERT INTO entry_contents (project_id, entry_id, stage, type_id, data, data_fold)
        SELECT :projectId, v.entry_id, v.stage, :typeId, v.data::jsonb, v.data_fold::jsonb
        FROM (SELECT * FROM unnest(:entryIds, :stages, :datas, :dataFolds) AS u(entry_id, stage, data, data_fold)) AS v
        ORDER BY v.entry_id, v.stage
        ON CONFLICT (project_id, entry_id, stage) DO UPDATE
            SET data = EXCLUDED.data, data_fold = EXCLUDED.data_fold, type_id = EXCLUDED.type_id, updated_at = now()
        RETURNING entry_id
    ), touched AS (
        UPDATE entries SET updated_at = now()
        WHERE project_id = :projectId AND deleted_at IS NULL AND id = ANY(ARRAY(SELECT entry_id FROM written))
    )
    SELECT DISTINCT entry_id FROM written
}
```

公開の Tx が entries と entry_contents をどの順で lock するかは N4 の前に読んで確かめ、fill と公開を並行に走らせる実 PG のテストを 1 件置く（4 節の N4）。

期待する生成物:

| query | シグネチャ | 本体 |
|---|---|---|
| `upsertContent` | `upsertContent(args: { entryId = String, stage = String, typeId = Int64, data = Json, dataFold = Json }): Int32 \ DbWrite + Tenant` | `Sql.execute`。返る数は `entries` の更新数（今は `entry_contents` の数。呼び手は全部 `discard`） |
| `fillMissingField` | `fillMissingField(args: { ... }): List[FillMissingFieldRow] \ DbWrite + Tenant`、`FillMissingFieldRow = { entryId = String }` | `Sql.executeReturningAs`（本文は SELECT だが CTE が書くので書き込み扱い。1.6） |
| `upsertContents` | `upsertContents(args: { ... }): List[UpsertContentsRow] \ DbWrite + Tenant` | 同上 |

PG の決まりで確かめた事: 書き込みの CTE と本文は同じ snapshot で動くので、`touched` は `filled` の `RETURNING` を読めるが、`filled` が書いた後の `entry_contents` は読めない。上の 3 つはどれも `RETURNING` だけを読む。削除済みの entry は中身が書け、`updated_at` は動かない（今の `touchEntry` と同じ）。

### 1.4 字句と解析の拡張

#### 先に直す字句（`SqlTokens` と `QParser` の両方）

`QCte` の前に、次の 2 つを字句の段で扱う。どちらも今の WITH の無い query にも効く直しで、1.1 の 3 つ目の素通りを塞ぐ。

| 形 | `SqlTokens.tokenize` | `QParser.bodyLoop` |
|---|---|---|
| `/* ... */`（PG と同じく入れ子を数える） | 落とす（語にしない） | 中の `:name` / `{` / `}` / `'` を見ない。PG に出す SQL には残す |
| dollar quote（`$$...$$`、`$tag$...$tag$`） | 文字列リテラルと同じく 1 語 | 中の `:name` / `{` / `}` / `'` を見ない |

`$1` の形（`$` + 数字）は今のまま `$n` の 1 語。`$` の後ろが英字か `$` の時だけ dollar quote と読む。

#### `Sqlfx.Q.QCte`

`QResolve` と `QScope` の両方が同じ切り方を使うので、語の並びを「CTE の並び + 本文」に切る所を 1 つの module に置く。

```
QCte.split(words: List[String]): Result[CteError, Statement]

Statement = { ctes = List[Cte], main = Unit }                          // WITH が無ければ ctes = Nil
Cte       = { name = String, columns = Option[List[String]], body = Unit }
Unit      = { words = List[String], start = Int32, end = Int32 }        // start / end は words 全体の中の位置
```

- 文法は 1.2 の「WITH の判定」。`RECURSIVE` を見たら `RecursiveCte`
- `name` は小文字にして持つ（PG は引用符の無い識別子を小文字に畳む）
- `start` / `end` は slot の位置（1.7）を決めるのに使う

#### `QResolve.resolve`

1. `QCte.split` で `Statement` にする
2. CTE の名前の検査: 同じ名前が 2 つ（`DuplicateCte`）、表の名前と同じ（`CteShadowsTable`）、`main`（`// unscoped:` で本文を指す語。1.8）
3. CTE を前から 1 つずつ、今の `resolve` の中身（`classifyStatement` → `collectSources` → `resolveColumnList`）で解決する。解決に使う schema は「migrations の schema + それより前の CTE を仮想の表にした物」
4. 解決した CTE を仮想の表にして足す。カラムは `ResultColumn` → `Column`（`columnType = Some(型)`、`nullable` はそのまま）。`columns` の並びがあれば位置で名前を付け替え、数が違えば `CteColumnCount`。`RETURNING` の無い書き込みの CTE はカラム 0 個の表として足し、`FROM` で読まれた所で `CteWithoutReturning` にする（0 個の表を `*` で読むと空になるだけで気づけないため）
5. 書き込みの文を全部並べ、書き込み先の表が 2 つ以上の文で重なれば `SameTableWrittenTwice`
6. 本文を同じ手順で解決し、結果のカラム・keyed の検査は本文に対して行う

仮想の表は `QResolve` の中だけの型 `Source`（`{ table, label, nullable, fromCte = Option[CteKind] }`）で持ち、`Schema.Table` に区別を足さない。`Codegen.renderTables` は migrations の schema だけを見るので、仮想の表は生成物に出ない。

#### `RETURNING` を解決する相手

今の `resolveColumnList` は、書き込みの `RETURNING` のカラムも文の全部の source から引く。`INSERT INTO posts ... SELECT ... FROM users RETURNING id` は `id` が `posts` と `users` の両方にあって `AmbiguousColumn` になるが、PG は `RETURNING` を書き込み先の表だけで読む。WITH を入れると `INSERT ... SELECT ... FROM <CTE>` が増えるので、ここを PG に合わせる。

| 文 | `RETURNING` を引く source |
|---|---|
| `INSERT INTO t ...` | `t` だけ |
| `UPDATE t ... FROM a, b` | `t` と `FROM` の後ろ |
| `DELETE FROM t USING a` | `t` と `USING` の後ろ |

### 1.5 CTE のカラムの型と NULL 可否

新しい規則は作らず、今の規則を CTE の本文にそのまま当てる。

| CTE の本文のカラム | 型 | NULL 可否 |
|---|---|---|
| 表のカラム（`entry_id`、`c.data`） | DDL の型 | DDL の NULL 可否。LEFT / FULL JOIN の相手なら NULL 可 |
| `RETURNING` のカラム | 1.4 の表の source の DDL の型 | DDL の NULL 可否 |
| 式（`count(*)::bigint! AS n`） | cast の型（cast が無ければ今と同じ `UntypedColumn`） | `!` があれば NOT NULL、無ければ NULL 可 |
| 前の CTE のカラム | その CTE で決まった型 | その CTE で決まった NULL 可否 |

本文側で CTE を読む時も同じで、CTE を LEFT JOIN の相手にすれば NULL 可になり、`w.n::bigint!` の `!` で NOT NULL と主張できる。`!` は `QRender.toSql` が本文全体から落とすので、CTE の中に書いた `!` も PG には届かない。

WhyNot: CTE のカラムを本文で使った時に NULL 可否を「本文の WHERE で NULL を除いたか」から推論しない。式の型を推論しない今の方針（`QResolve` の冒頭の WhyNot）と同じく、書き手が `!` で主張し、実行時の decode が検証する。

### 1.6 書き込みの判定と生成物

- `Resolved#writes` は「本文が書き込み、または CTE のどれかが書き込み」にする。`WITH w AS (DELETE ... RETURNING id) SELECT id FROM w` は `DbWrite` + `Sql.executeReturningAs` になる
- 形（shape）の判定は本文だけで行う（`shapeFits`）。本文が SELECT か `RETURNING` 付きの書き込みなら one / many、本文が `RETURNING` の無い書き込みなら exec。`WITH w AS (UPDATE ...) SELECT 1` を exec にするのは断る（pgjdbc の `executeUpdate` は結果の row を返す文を例外にするため）
- `Codegen` は `(shape, writes)` で選ぶ今の形のままで足りる。生成物の形は変わらないので、ジェネレータのバージョン（`Codegen.version()` の `"10"`）は上げない

WhyNot: CTE が書くのに `DbRead` にしない。nextcms は読むだけの文書を `READ ONLY` の Tx で走らせ、型で `DbWrite` を入れさせない事で守っている。CTE の書き込みを `DbRead` に数えると、その守りを型の検査が素通りし、実行時に PG の `25006` で落ちる。

### 1.7 slot

- `Pred` / `Order` の slot は CTE の本文にも本文にも置ける。slot の表（`Pred[entries]`）は、その `{slot}` を含む文の table source に在る事を求める（今の `checkSlots` は query 全体の source を見るので、CTE を入れると「別の文の source に在るから通る」が起きる）
- どの文に `{slot}` が在るかは、`SlotRef` の断片の位置から決める。`QRender` が解決用の SQL を組む時に、各 `SlotRef` の手前までの素の SQL を `SqlTokens.tokenize` した語の数を控え、それが `QCte` の `Unit` の `start` / `end` のどれに入るかで文を決める。PG に出す SQL（`toSql`）は今のまま
- `Changes` は 1.2 のとおり WITH を含む query では断る（`ChangesSlotWithCte`）

### 1.8 `--scope project_id:Tenant` を CTE の中の各文に効かせる

#### 決め 1: 文の単位で検査する

`QScope` も `QCte.split` を使い、WITH を含む query では検査の単位を「CTE の本文 1 つずつと、本文」にする。本文にだけ条件を書き、CTE の DELETE に条件の無い次の形を止めるため。

```sql
WITH gone AS (
    DELETE FROM entry_contents WHERE entry_id = :entryId RETURNING entry_id      -- project_id の条件が無い
)
UPDATE entries SET updated_at = now() WHERE project_id = :projectId AND id = ANY(ARRAY(SELECT entry_id FROM gone))
```

#### 決め 2: WITH を含む query の文は、最初から厳しい規則で検査する

「単位の語にカラム名が 1 度出れば通す」では 1.1 の素通りが CTE の中でも起きる。WITH を含む query は 0.5.0 では書けなかったので、厳しい規則を入れても既存の `.q` は止まらない。WITH を含む query の各単位に、次の規則を当てる。

| 規則 | 見る所 |
|---|---|
| R1. 触る表を全部拾う | `FROM` / `JOIN` / `INTO` / `UPDATE` / `USING` の後ろと、`FROM` / `USING` のカンマの続き。深さを問わない（副問い合わせの中も）。表の綴りは `ONLY t`、`public.t`、`"t"` を `t` に揃える。CTE の名前は数えない |
| R2. scope のカラムを持つ表は、それぞれ「縛られている」事 | その表（か label）の scope のカラムが、同じ単位の中で引数（`= :p`、`= ANY(:p)`、`IN (:p)`）と比べられている。または、縛られた別の表の scope のカラムと `=` で比べられている（結合の条件は、相手が縛られている時だけ数える。`a.project_id = b.project_id` だけでは、どちらも縛られていない） |
| R3. `INSERT` の書き込み先 | カラムの並びに scope のカラムがあり、その位置の値が引数（`VALUES` の `:p`）か、縛られた読み元の scope のカラム（`INSERT ... SELECT` の SELECT リストの同じ位置）。`INSERT ... SELECT` の読み元の表は R2 で検査する |
| R4. SELECT リストと文字列とコメント | どれも「縛る」に数えない |

WITH の無い query には、今の粗い検査を残す。R1〜R4 を WITH の無い query にも当てるかは、nextcms の `queries/*.q` 全部に当てて止まる件数を数えてから決める（5 節の C7 の前の計測。今の `touchedTables` に `USING` とカンマの続きを足した時の件数も同じ計測で数える）。止まる件数が多ければ、止まった query を直す PR を nextcms 側で先に出し、sqlfx の次の minor で WITH の無い query にも当てる。

#### 決め 3: `// unscoped:` は WITH を含む query では文を名指しする

WITH を含む query の免除は、免除する文の名前を書かせる。書いていない文は検査する。

```
// unscoped: [カラム] in <CTE の名前 | main>[, ...] 理由
```

- `main` は本文を指す。CTE の名前に `main` は使えない（1.4 の 2）
- WITH を含む query に `in` の無い `// unscoped:` を書くと `UnscopedMarkerNeedsStatement`（エラーメッセージは 1.9）
- 書いた名前の CTE が無ければ `UnknownMarkedStatement`
- `// scope: explicit` は今のまま query 単位（引数を注入するかどうかの決めで、検査を外すものではないため）
- WITH の無い query の `// unscoped:` は今のまま

#### 注入

注入（`injection`）は query 単位のまま。同じ `:projectId` を複数の単位で使っても、`QRender` が同じ名前に同じ `$n` を振るので引数は 1 つ。

#### 漏れる形の洗い出し（WITH を含む query）

| # | 形 | 検査の結果 | 備考 |
|---|---|---|---|
| 1 | CTE の本文が scope の表を条件無しで触り、本文にだけ条件 | 止まる（決め 1） | 上の例 |
| 2 | 本文が scope の表を、CTE から来た id だけで絞る（`WHERE id = ANY(ARRAY(SELECT entry_id FROM w))`） | 止まる（R2） | 誤検知ではない。nextcms の `entries` の主キーは `(project_id, id)` で、id だけでは別のプロジェクトの row に当たりうる |
| 3 | 本文が CTE だけを読む（`SELECT entry_id FROM filled`） | 通る | scope の表を触っていない |
| 4 | 入れ子の WITH | 断る（`NestedWith`） | |
| 5 | CTE の名前が scope の表と同じ | 断る（`CteShadowsTable`） | |
| 6 | 前の CTE を後ろの CTE の `FROM` で読む | 通る | 読まれた側は自分の単位で検査済み |
| 7 | 単位の中の副問い合わせが scope の表を条件無しで触り、外側は縛られている | 止まる（R1 は深さを問わない、R2 は表ごと） | WITH の無い query では今と同じく通る（決め 2 の計測の後に決める） |
| 8 | カラム名が SELECT リストにだけ出る | 止まる（R4） | 同上 |
| 9 | `WITH RECURSIVE` | 断る | |
| 10 | カラム名が文字列リテラル・`--` コメント・`/* */` コメント・dollar quote にだけ出る | 止まる（R4 と 1.4 の字句） | `/* */` は 0.5.0 では通っていた（1.1 の 3 つ目）。字句の直しで WITH の無い query でも止まる |
| 11 | `INSERT INTO <scope の表> ... SELECT ... FROM <scope の表>` で、読み元が縛られていない | 止まる（R3） | 0.5.0 では通っていた（1.1 の 1 つ目） |
| 12 | `DELETE ... USING <scope の表>` / `UPDATE ... FROM a, <scope の表>` の `USING` やカンマの続きが縛られていない | 止まる（R1 と R2） | 0.5.0 では通っていた（1.1 の 2 つ目） |
| 13 | 結合の条件だけ（`a.project_id = b.project_id`）で、どちらも引数に縛られていない | 止まる（R2） | |
| 14 | 表の綴りが `ONLY t` / `public.t` / `"t"` | 通らない（R1 で `t` に揃えて検査する） | |
| 15 | `// unscoped:` で CTE を 1 つ免除し、別の CTE に条件が無い | 止まる（決め 3） | |

### 1.9 エラーメッセージ

`ResolveError` は今 `ToString` の綴り（`UnknownTable(q, t)`）のまま出ている。`QScope.describe` と同じく「規則・受け取った値・直し方」の 1 line にする `QResolve.describe` を足し、`Gen.renderOne` はそれで出す。新しく足す case:

| case | メッセージ |
|---|---|
| `RecursiveCte(query, cte)` | `query X uses WITH RECURSIVE (CTE Y), which the generator does not type. Put the recursive part in a SQL function and SELECT from it, or run it with RawSql` |
| `NestedWith(query)` | `query X has a WITH inside a CTE or a subquery. The generator reads only the WITH at the start of the query; move the inner CTEs up into it` |
| `DuplicateCte(query, cte)` | `query X defines CTE Y twice. Rename one of them` |
| `CteShadowsTable(query, cte)` | `CTE Y in query X has the name of a table. Rename the CTE: PostgreSQL reads FROM Y as the CTE but UPDATE Y as the table, and the scope check needs one meaning` |
| `ReservedCteName(query)` | `query X names a CTE main, which is how // unscoped: points at the main statement. Rename the CTE` |
| `CteColumnCount(query, cte, declared, actual)` | `CTE Y in query X names 2 columns, but its statement returns 3. Make the list after the CTE name match the statement's columns` |
| `CteWithoutReturning(query, cte)` | `query X reads CTE Y, which writes without RETURNING, so it has no columns. Add RETURNING <columns> to CTE Y` |
| `SameTableWrittenTwice(query, table, first, second)` | `query X writes table T in both A and B. PostgreSQL applies only one of two changes to the same row in one statement (the manual, 7.8.4), so one of them would be lost without an error. Merge them into one statement, or split the query` |
| `ChangesSlotWithCte(query, slot)` | `slot S of query X is Changes, which cannot be used in a query with WITH: when the changes are empty the whole statement is skipped, and so are the other CTEs' writes. Split the query` |
| `SlotTableNotInStatement(query, slot, table)` | 今の `SlotTableNotInFrom` を置き換える。`slot S of query X is Pred[T], but T is not in the FROM of the statement that holds {S}` |

`QScope` に足す case:

| case | メッセージ |
|---|---|
| `Unscoped`（WITH を含む query では文の名前を足す） | `query X touches T in CTE Y (or: in the main statement) with no condition that ties T.project_id to a parameter. Compare it with a parameter, join it to a table that is, or write // unscoped: in Y <reason>` |
| `UnscopedMarkerNeedsStatement(query)` | `query X has WITH, so // unscoped: must name the statements it exempts: // unscoped: in <CTE name or main> <reason>` |
| `UnknownMarkedStatement(query, name)` | `// unscoped: of query X names Y, which is neither a CTE of the query nor main` |

QLint の警告: `query X: CTE Y is a SELECT that nothing reads. PostgreSQL does not run it; read it in FROM or remove it`。

### 1.10 テスト計画（純粋な物なのでテストファースト）

どれも DB 無しで回る（`make test-unit`）。表は `List#{(入力, 期待)}` で 1 assert。schema は今の `TestQResolve.blogSchema()`（users / posts）に、scope の表として `project_id` のカラムを持つ `entries(project_id, id, type_id, version, updated_at, deleted_at)` と `entry_contents(project_id, entry_id, stage, type_id, data, data_fold)` を足す。

#### `test/Q/TestSqlTokens.flix` / `TestQParser.flix`（字句）

| 入力 | 期待 |
|---|---|
| `SELECT id FROM entries /* project_id */ WHERE id = $1` | 語に `project_id` が無い |
| `SELECT 1 /* a /* b */ c */ + 2` | 入れ子を数え、語は `SELECT 1 + 2` |
| `SELECT id FROM t /* ( */ WHERE x = 1` | 括弧の深さが崩れない（`FROM` の後ろの `t` を拾う） |
| `SELECT $$it's :x {y}$$ AS s` | 1 語のリテラル。QParser は `:x` を引数に、`{y}` を slot にしない |
| `SELECT $tag$ a $$ b $tag$` | 1 語 |
| `SELECT $1, $2` | `$1`、`$2` の 2 語（今のまま） |
| `.q` の本文 `SELECT id FROM entries /* it's :projectId ( */ WHERE project_id = :projectId` | `ParamRef` は 1 つ（コメントの外の物だけ）、`'` で引用に入らない |

#### `test/Q/TestQCte.flix`（切り方）

| 入力（本文の語） | 期待 |
|---|---|
| `SELECT 1` | ctes = Nil、main = 全部 |
| `WITH a AS (SELECT id FROM users) SELECT id FROM a` | ctes = [a]、main = `SELECT id FROM a`、start / end が語の位置 |
| `WITH a AS (...), b AS (...) SELECT ...` | ctes = [a, b] の順 |
| `WITH w(x, y) AS (...) ...` | columns = Some([x, y]) |
| `WITH a AS MATERIALIZED (...) ...` / `NOT MATERIALIZED` | 読み飛ばし |
| `WITH A AS (...) SELECT * FROM a` | 名前は `a` |
| `SELECT now()::timestamp with time zone AS t` | ctes = Nil（WITH を CTE と読まない） |
| `SELECT v.n FROM unnest(:a) WITH ORDINALITY AS v(n, i)` | ctes = Nil |
| `WITH a AS (SELECT x::timestamp with time zone AS t FROM y) SELECT t FROM a` | ctes = [a]（CTE の中の `with time zone` は NestedWith にしない） |
| `WITH RECURSIVE t AS (...) ...` | `Err(RecursiveCte("t"))` |
| `WITH a AS (WITH b AS (SELECT 1) SELECT * FROM b) SELECT * FROM a` | `Err(NestedWith)` |
| `SELECT * FROM (WITH b AS (SELECT 1) SELECT * FROM b) s` | `Err(NestedWith)` |
| `SELECT 'with a as (' AS w` | ctes = Nil（リテラル） |
| `WITH a AS (SELECT 1` | `Err(Unexpected)` |

往復: WITH の無い本文は `split` の `main#words` が入力と同じ（今の全 `.q` のテストがそのまま通る事で確かめる）。

#### `test/Q/TestQResolve.flix` に足す節「CTE」

| .q | 期待（カラム, writes） |
|---|---|
| `many { WITH a AS (SELECT id, email FROM users) SELECT id, email FROM a }` | (id Int64 NOT NULL, email String NULL 可)、false |
| `many { WITH a AS (SELECT count(*)::bigint! AS n FROM posts) SELECT n FROM a }` | (n Int64 NOT NULL)、false |
| `many { WITH a AS (SELECT count(*)::bigint AS n FROM posts) SELECT a.n::bigint! AS n FROM a }` | (n NOT NULL。本文の `!` が勝つ) |
| `many { WITH a AS (SELECT id FROM users) SELECT u.id, a.id AS aid FROM users u LEFT JOIN a ON a.id = u.id }` | aid は NULL 可 |
| `many { WITH w(x) AS (SELECT id FROM users) SELECT x FROM w }` | (x Int64 NOT NULL) |
| `many { WITH a AS (SELECT id FROM users), b AS (SELECT id FROM a) SELECT id FROM b }` | (id Int64 NOT NULL) |
| `exec { WITH w AS (UPDATE users SET name = :n WHERE id = :id RETURNING id) UPDATE posts SET title = :t WHERE user_id = ANY(ARRAY(SELECT id FROM w)) }` | カラム無し、true |
| `many { WITH w AS (DELETE FROM posts WHERE id = :id RETURNING id) SELECT id FROM w }` | (id Int64 NOT NULL)、**true** |
| `one { WITH w AS (INSERT INTO users (name) VALUES (:n) RETURNING id) INSERT INTO posts (user_id, title) SELECT id, :t FROM w RETURNING id }` | (id)、true。`RETURNING id` は posts だけで引く（w の id と曖昧にならない） |
| `one { INSERT INTO posts (user_id, title) SELECT id, :t FROM users WHERE id = :u RETURNING id }`（WITH 無し） | (id)。0.5.0 の `AmbiguousColumn` が通るようになる |
| 1.3 の 3 つ | 1.3 の表の通り |

エラー:

| .q | 期待 |
|---|---|
| `many { WITH b AS (SELECT id FROM a), a AS (SELECT id FROM users) SELECT id FROM b }` | `UnknownTable(q, "a")`（前方参照） |
| `many { WITH a AS (SELECT 1::int AS x), a AS (SELECT 2::int AS x) SELECT x FROM a }` | `DuplicateCte(q, "a")` |
| `many { WITH users AS (SELECT id FROM posts) SELECT id FROM users }` | `CteShadowsTable(q, "users")` |
| `many { WITH main AS (SELECT id FROM posts) SELECT id FROM main }` | `ReservedCteName(q)` |
| `many { WITH w(x, y) AS (SELECT id FROM users) SELECT x FROM w }` | `CteColumnCount(q, "w", 2, 1)` |
| `many { WITH w AS (UPDATE users SET name = :n) SELECT * FROM w }` | `CteWithoutReturning(q, "w")` |
| `exec { WITH b AS (UPDATE entries SET version = version + 1 WHERE ... RETURNING id) UPDATE entries SET updated_at = now() WHERE ... }` | `SameTableWrittenTwice(q, "entries", "b", "main")` |
| `exec { WITH a AS (UPDATE posts SET ... RETURNING id), b AS (DELETE FROM posts WHERE ...) SELECT 1 }` | `SameTableWrittenTwice(q, "posts", "a", "b")`（exec の本文の件より先に出す） |
| `exec { WITH w AS (UPDATE users SET name = :n RETURNING id) SELECT id FROM w }` | `UnsupportedStatement`（exec の本文が SELECT） |
| `exec with c: Changes[users] { WITH w AS (SELECT 1::int AS x) UPDATE users SET {c} WHERE id = :id }` | `ChangesSlotWithCte(q, "c")` |
| `many with f: Pred[posts] { WITH a AS (SELECT id FROM users WHERE {f}) SELECT id FROM a }` | `SlotTableNotInStatement(q, "f", "posts")` |
| `many with f: Pred[users] { WITH a AS (SELECT id FROM users WHERE {f}) SELECT p.id FROM posts p }` | 通る |
| `many with f: Pred[posts] { WITH a AS (SELECT id FROM posts) SELECT u.id FROM users u WHERE {f} }` | `SlotTableNotInStatement`（posts は別の文にだけ在る） |

#### `test/Q/TestQScope.flix` に足す節「CTE の中の各文」

`--scope project_id:Tenant`。

| .q | 期待 |
|---|---|
| 1.3 の 3 つ | 通る。注入は `projectId`、`$n` は 1 つ |
| CTE の DELETE に条件無し、本文に条件（1.8 の例） | `Unscoped`、メッセージに `in CTE gone` |
| CTE に条件、本文の `UPDATE entries` は id だけで絞る | `Unscoped`、`in the main statement` |
| CTE に条件、本文は CTE だけを読む | 通る |
| CTE の中で `INSERT INTO entry_contents (...) SELECT project_id, id, ... FROM entries WHERE id = :entryId` | `Unscoped(entries)`（11 番。SELECT リストの `project_id` は数えない） |
| CTE の中で `INSERT INTO entry_contents (project_id, ...) SELECT e.project_id, ... FROM entries e WHERE e.project_id = :projectId AND ...` | 通る（読み元が縛られ、書き込み先の値は縛られた読み元のカラム） |
| CTE の中で `DELETE FROM users u USING entries e WHERE e.id = :entryId AND ...` | `Unscoped(entries)`（12 番） |
| CTE の中で `UPDATE entry_contents c SET ... FROM users u, entries e WHERE c.project_id = :projectId AND ...` | `Unscoped(entries)`（12 番、カンマの続き） |
| CTE の中で `UPDATE entry_contents c SET ... FROM entries e WHERE c.project_id = e.project_id AND e.id = :id` | `Unscoped`（13 番。どちらも引数に縛られていない） |
| 上に `AND e.project_id = :projectId` を足す | 通る（e が縛られ、c は結合で縛られる） |
| CTE の中で `UPDATE ONLY public."entries" SET ... WHERE id = :id` | `Unscoped(entries)`（14 番） |
| CTE の中で `SELECT id FROM entries WHERE id = :id AND x IN (SELECT entry_id FROM entry_contents)` に外側だけ `project_id = :projectId` | `Unscoped(entry_contents)`（7 番） |
| CTE の中で `SELECT id FROM entries /* project_id */ WHERE id = :id` | `Unscoped(entries)`（10 番） |
| 1 番の形に `// unscoped: in gone 理由` | 通る |
| 1 番の形に `// unscoped: 理由`（`in` 無し） | `UnscopedMarkerNeedsStatement` |
| 1 番の形に `// unscoped: in other 理由` | `UnknownMarkedStatement` |
| `// unscoped: in gone 理由` で、本文の `UPDATE entries` にも条件が無い | `Unscoped`（15 番。免除は gone だけ） |
| `// scope: explicit project_id 理由` で `:projectId` を CTE と本文の両方で使う | 通る、注入無し、引数 `projectId` が残る |
| WITH の無い今の表のテストの全部 | 今と同じ答え |
| WITH の無い `SELECT id FROM entries /* project_id */ WHERE id = :id` | `Unscoped`（字句の直しで 0.5.0 から変わる。3 節の破壊的変更） |

#### `test/Q/TestCodegen.flix` / `TestGen.flix`

| 入力 | 期待する生成物の line |
|---|---|
| `many { WITH w AS (DELETE ... RETURNING id) SELECT id FROM w }` | `\ DbWrite` と `Sql.executeReturningAs` |
| `many { WITH a AS (SELECT ...) SELECT ... }` | `\ DbRead` と `Sql.fetchAs` |
| 1.3 の 3 つを `--scope project_id:Tenant` で | 1.3 の表のシグネチャ |
| `gen --statements <path>`（N5 用。1.11） | 1.11 の形の JSON |

#### 実 PG（`examples/blog`）

`examples/blog/queries/posts.q` に「投稿を消して、書き手の `updated_at` を動かす」CTE の query を 1 つ足し、生成物を commit、`examples/blog/test/Pg` で「影響した数・RETURNING の値・両方の表の row」を 1 assert で見る。`make test-examples` の `gen --check` で生成物の鮮度も見る。

### 1.11 文の一覧を外に出す（`gen --statements`）

nextcms の entry-touch の check（N5）は「`entry_contents.data` を書く文を含む query に、`entries.updated_at` を書く文もあるか」を見たい。Go 側に SQL のパーサをもう 1 つ持たないよう、ジェネレータが解決した結果を書き出す。

```
bin/flix run -- gen --statements <path> [--scope ...] <migrations/> <queries/> <out/>
```

`<path>` に JSON を書く（`gen --check` は中身も突き合わせる）。1 query 1 レコード:

```json
{ "file": "entries.q", "query": "upsertContent",
  "statements": [
    { "name": "written", "kind": "insert", "target": "entry_contents", "columns": ["project_id", "entry_id", "stage", "type_id", "data", "data_fold"], "conflictSet": ["data", "data_fold", "type_id", "updated_at"] },
    { "name": "main", "kind": "update", "target": "entries", "columns": ["updated_at"] } ] }
```

`columns` は INSERT のカラムの並びか UPDATE の SET の左辺、`conflictSet` は `ON CONFLICT DO UPDATE SET` の左辺。SELECT の文は `target` 無し。

---

## 2. 改修 2: fatal の例外でも接続を返す

### 2.1 今の経路と穴

`Pool.withLazyTxResultAfterBegin` の後始末（COMMIT / ROLLBACK と `Jdbc.close`）は `run ... with handler` を抜けた後の普通のコードで、`Throwable` が `run` の外まで抜けると走らない。例外の出所ごとに並べる（0.5.0 のコードを読んだ物と、scratchpad の実測）。

| # | 例外の出所 | 0.5.0 | 結果 |
|---|---|---|---|
| a | thunk の本体（ライブラリの `Db.guard` の内側）、fatal でない | `DbErr.other` → ROLLBACK → 返す | 返る |
| b | thunk の本体、fatal | `Db.guard` がその場で `throw` | **漏れる** |
| c | `onBegin`、fatal | 同上（`Db.guard(onBegin)`） | **漏れる** |
| d | SqlRead / SqlWrite / SqlSavepoint の handler の本体（`Jdbc.fetchRows` 等と、その中の `open()`）、`SQLException` 以外の全部 | handler の本体が投げた物は `run` の外へ抜ける | **漏れる**（fatal でなくても） |
| e | 利用側が thunk の中に張った handler の内側、`Db.guard` 無し | ライブラリの catch に届かない | 漏れる。直らない（2.3 の最後） |
| f | 利用側の handler の内側の `Db.guard`、fatal | その場で `throw` | **漏れる** |
| g | 後始末の `Tx.commit` の中、fatal | `Tx.commit` は `SQLException` しか catch しない | **漏れる** |
| h | `Pool.withConnection` / `withConnectionTimeout` の thunk と handler の本体、`SQLException` 以外 | `runOnConnection` は catch しない | **漏れる**（fatal でなくても） |
| i | `Jdbc.withConnection` の同上 | 同上 | 物理接続が GC まで開いたまま |
| j | `Db.attempt` / `Tx.withSavepoint` / `DbError.runWithFailure` のような、sqlfx が利用側の thunk を包んで handler を張る所の中で、外の handler へ op を投げた後に投げた物 | その `run` の中の throw は、外側のライブラリの `Db.guard` を素通りする（2.2 の 4 番目） | **漏れる（fatal でない `RuntimeException` でも）**。`Db.attempt(() -> Tx.withSavepoint("sp", () -> { INSERT; throw }))` で active=1 のまま残る事を実測した |
| k | `open()` の `Tx.begin` の失敗 | 接続を `slot` に置くのが `Tx.begin` の後なので、BEGIN が失敗すると借りた接続を誰も返さない | **漏れる** |

nextcms の `DbRunner.returningConnection` / `guardTx` が塞いでいるのは b と f で、d / g / j は塞げていない。nextcms の `ContentEntries.aggregatingResult`（`Tx.withSavepoint` の中で `StatementTimeout.withTimeout` を張る）は j と同じ形。RequestTx（`DbRunner` の 380 line 付近）は自前の SqlRead の handler を持ち、d と同じ穴がある。

### 2.2 前提: try / catch が届く位置（実測の表）

nextcms の `test/app/TestJvmCatchNesting.flix` の表に、scratchpad の spike（Flix 0.75.3 と 0.76.0 の両方で同じ結果）で確かめた形を足した物。

| 形 | 拾えるか |
|---|---|
| `try { run { op; throw } }`（handler が try の内側） | 拾える |
| `run { try { op; throw } }`（try の直下から外の handler へ op。間に run 無し） | 拾える |
| `run { try { run { op }; throw } }`（op を通した run を抜けた後で throw） | 拾える |
| `run { try { run { op; throw } } }`（外へ op を通した run の中で throw） | **素通り** |
| `run { try { op } } with handler { def op = throw }`（handler の本体が投げ、handler は try の外） | **素通り** |
| handler の本体の中に try を置き、その中で JDBC を呼ぶ（thunk が外の handler に op を投げた後でも） | 拾える（spike S1-A / B / C2） |
| handler の本体の try の中で `resume` を呼ぶ | **形による**（spike S1-E は素通り）。`resume` の後で thunk が外の handler へ op を投げていれば素通り、投げていなければ本体の try が thunk の例外まで拾う（C1 の `TestCatchNesting` で 3 通りを実測。spike S1-E の「素通り」は前者の形にだけ当たる）。拾う時は利用側の例外を handler が飲み込むので、どちらにしても網にならない |

ここから決まる事:

- `withLazyTx` の `run` を外から try で包んでも網にならない（4 番目）
- handler の本体の throw は、本体の中に try を置けば拾える。**`resume` は try を抜けてから呼ぶ**
- thunk の本体の throw は、今の `Db.guard` の位置（一番内側の handler の直下）で拾える
- sqlfx が利用側の thunk を包んで張る `run`（j）は、**その `run` の直下に catch を置き、`run` を抜けてから投げ直せば**、3 番目の形で外側の `Db.guard` に届く

### 2.3 設計

#### 方針: fatal は値にしない。拾った所で evict し、その場で投げ直す

fatal を拾う所は、どれも接続（`withLazyTx` の region の `Ref`）に手が届く所に置く。拾ったら、借りていれば接続を evict して、その場で投げ直す。接続はもうプールに無いので、投げ直した例外が後始末を飛ばしても漏れない。fatal を `DbErr` の値にしないので、fatal を飲み込む経路も、fatal の後に利用側のコードが動き続ける経路も作らない。

WhyNot: fatal を Tx ごとの slot に覚えておき、Tx の出口でまとめて投げ直す形（`ThreadLocal`）にしない。Flix にトップレベルの値が無く、`ThreadLocal` の置き場が JVM 全体の `System.getProperties()` しか無い。さらに、Tx の外で受けた非再開の effect（利用側の誤り）や 2.1 の e で出口が走らないと slot がスレッドに残り、その後の Tx の外の `Db.guard` が OOM を `DbErr` の値にして飲み込む事を実測した（spike S4-stale / S4-escape）。

WhyNot: fatal をいったん値にして Tx の出口で投げ直す形（nextcms の `guardTx`）を sqlfx の公開 API にしない。利用側が Tx の外で非再開の effect を受けると出口が走らず、覚えた fatal が消える。sqlfx はその形を利用側に禁じられない。nextcms は自分の Tx の形を lint で縛っているので、`guardTx` を自分の側に残す（4 節）。

#### 拾う所

| 所 | 置き方 | 拾った後 |
|---|---|---|
| A. handler の本体（`withLazyTx*` / `Pool.withConnection*` / `Jdbc.withConnection` / `Tx.withTx` の SqlRead / SqlWrite / SqlSavepoint の全部の口） | `let r = catchAll(() -> DbError.runWithKind(() -> Jdbc.fetchRows(open(), ...)))`。try の外で `resume` | fatal: 借りていれば evict、投げ直す。fatal でなく pgjdbc の中から出た物: 「接続の状態が分からない」フラグを立て、`Err(Other(...))` で resume。それ以外: `Err(Other(...))` で resume |
| B. thunk と onBegin（今の `Db.guard` の位置） | ライブラリの中だけの `guardOn(conn, thunk)`（接続の `Ref` を閉じ込めた `Db.guard`） | fatal: 借りていれば evict、投げ直す。fatal でない: 今と同じ `DbErr.other` |
| C. 後始末（`Tx.commit` / `Tx.rollback`） | `catchAll` で包む | fatal: evict、投げ直す（COMMIT 中なら 2.4 の marker を付ける）。ROLLBACK の失敗: evict |
| D. sqlfx が利用側の thunk を包んで張る `run`（`DbError.runWithKind` と、それを使う `runWithFailure` / `Db.attempt` / `onConstraintWith` / `Tx.withSavepoint`、`Retry.withRetry*`、`RawSql.runWithAllow`） | `run { Ok(catchAll(thunk)) } with handler ...`（catch を `run` の直下に）。`run` を抜けてから `Err` の `Throwable` を投げ直す | 変換しない（fatal もそうでない物もそのまま投げ直す）。外側の A / B に届かせるためだけの catch |

「pgjdbc の中から出た」は、例外の class 名か stack trace の先頭の frame の class 名が `org.postgresql.` で始まる事で決める。pgjdbc の中の `RuntimeException` は protocol の途中で出うるので、その接続は捨てる。`JdbcConvert` のような sqlfx 側の変換の失敗は、接続の protocol に触っていないので、今のとおり ROLLBACK して返す。

`Db.guard`（公開）は今のまま、fatal をその場で投げる。利用側が自分の handler の内側に置いた `Db.guard` の fatal（2.1 の f）は、0.6.0 でも漏れる。README の「Shapes that break」に、利用側の handler を張るなら nextcms の `guardTx` の形（fatal を覚えて `DbErr` にし、Tx が返った後で投げ直す）を自分の側で書く事と、その形は Tx の外で非再開の effect を受けない前提の上でしか成り立たない事を書く。

`Db.isFatal` は cause の連鎖も見るようにする（深さ 8 まで）。nextcms の `JvmErrors.isFatal` と同じ判定で、graphql-java が `CompletionException` に包んだ `OutOfMemoryError` を fatal と見るため（spike の T15 で 0.5.0 は `Other` にしていた）。

#### `open()` の順

借りた直後に接続を `Ref` に置き、その後で `Tx.begin` と onBegin を流す（2.1 の k）。BEGIN が `SQLException` で失敗しても、後始末が `Ref` の接続を ROLLBACK して返せる。

#### 後始末（`run` を抜けた後）

fatal はこの時点では来ない（A / B / C でその場で投げている）。

| 接続 | フラグ | outcome | すること |
|---|---|---|---|
| 借りていない | - | 何でも | 今と同じ |
| 借りている | あり | 何でも | evict、outcome（`DbErr.other`）を返す |
| 借りている | 無し | `Ok(Ok)` | COMMIT → close。COMMIT 中の fatal は C |
| 借りている | 無し | それ以外 | ROLLBACK → close。ROLLBACK が失敗したら evict |

`Pool.withConnection` / `withConnectionTimeout` / `Jdbc.withConnection` も同じ表（COMMIT の段が無いだけ）。`Jdbc.withConnection` はプールを持たないので、evict の代わりに物理接続を close する。

`Tx.withTx(conn, thunk)` と `Jdbc.runWithConnection(conn, thunk)` は、接続が呼び手の物で evict できない。A で fatal を拾ったら ROLLBACK を送らずに投げ直す。`Pool.withConnection(pool, conn -> Tx.withTx(conn, ...))` の形で `Tx.withTx` の handler の本体の fatal が出ると、`Pool.withConnection` の後始末が飛んで漏れうる（2.2 の 4 番目）。README に「プールの接続で Tx を張るなら `Pool.withLazyTx*` を使う」と書く（7 節）。

#### 直らない物

2.1 の e（利用側の handler の内側で `Db.guard` を置かずに投げる）と f（利用側の handler の内側の `Db.guard` の fatal）。どちらも、ライブラリ側にそれを拾える位置が無い。`TestPoolLeaks.testPoolLazyTxHandlerInsideWithoutGuardLeaks` は期待を変えずに残す。

### 2.4 evict・ROLLBACK の失敗・COMMIT の途中

- **evict の後に close を呼ばない。** HikariCP 5.1.0 の実測（spike S2x と、DB の側の `EvictProbe` / `AbortProbe`）:

  | 手順 | 結果 |
  |---|---|
  | evict → close（Tx の中で書いた後） | 本物の接続に ROLLBACK が送られる。ROLLBACK が止まると close も 3 秒止まる |
  | evict → close（Tx の中、まだ書いていない） | `PoolBase.resetConnectionState` が `NullPointerException`。fatal がこの NPE にすり替わる（spike の T3 / T4） |
  | 物理接続の abort → close | pgjdbc の「既にクローズされています」の例外 |
  | **evict だけ** | どの組み合わせでも active=0、次の借りは新しい backend pid、本物の接続への ROLLBACK / setAutoCommit / clearWarnings の呼び出しは 0 |

  evict した接続の PG 側の Tx は、物理接続が閉じた所で PG が ROLLBACK する
- **ROLLBACK が失敗したら evict。** 今の `Tx.rollback` は失敗を握り潰して close するので、`autocommit = false` のまま接続がプールに戻りうる。`Tx.rollback` の戻り値を `Bool`（成功したか）にする
- **接続が既に壊れている時**（SQLState `08` の例外）: HikariCP が自分で evict する。sqlfx 側は何も足さない
- **COMMIT の途中の fatal:** COMMIT が PG に届いたかは分からない。evict して投げ直す時に、fatal に `Throwable.addSuppressed` で marker の例外（`Sqlfx.CommitOutcomeUnknown`。message に「COMMIT の最中」）を足す。fatal の型は変えない。OOM の中で marker の例外を作れなければ、付けずに元の fatal を投げる（`addSuppressed` の失敗は握り潰す）。nextcms はこの marker を見て `db.tx.outcome: unknown` をログに出す（4 節の N2）

### 2.5 場面ごとの振る舞い

| 場面 | 振る舞い |
|---|---|
| 遅延 Tx で、まだ借りていない（SQL を出していない thunk の fatal） | B が拾い、evict する物が無いのでそのまま投げ直す |
| `open()` の中（`borrow` / `Tx.begin`）の fatal | A の try の中。借りていれば evict |
| onBegin の中の fatal | B（`guardOn(conn, onBegin)`）が evict して投げ直す |
| `Tx.withSavepoint` の thunk の中の fatal（`Db.guard` の有無を問わない） | D（`withSavepoint` の `run` の直下）が拾って `run` の外で投げ直し、外の `Db.attempt` の D も同じく投げ直し、B が evict して投げ直す。ROLLBACK TO は送らない |
| 同じ所の `RuntimeException` | D が投げ直し、B が `DbErr.other` にする。Tx は ROLLBACK → close |
| `Retry.withRetry(n, () -> Pool.withLazyTx(...))` の中の fatal | fatal は例外のまま Retry を通り抜ける（Retry は `TransientDbErr` だけを受ける）。再試行しない |
| COMMIT の最中の fatal | C。evict、marker を付けて投げ直す |
| `StackOverflowError` | 今と同じく fatal でない（`DbErr.other`、ROLLBACK、接続は返る） |

### 2.6 公開 API の変化

| API | 0.5.0 | 0.6.0 |
|---|---|---|
| `Db.guard` | fatal はその場で投げる | 変わらない |
| `Db.isFatal` | 例外そのものだけを見る | cause の連鎖も見る（深さ 8） |
| `Pool.withLazyTx*` | 2.1 の b / c / d / g / j / k で漏れる | 返る。fatal は evict の後にその場で投げる |
| `Pool.withConnection` / `withConnectionTimeout` / `Jdbc.withConnection` | thunk や handler の本体の `SQLException` 以外の例外はそのまま抜け、接続が漏れる | fatal でない物は `DbErr.other`、fatal は evict（close）の後に投げる |
| `DbError.runWithKind` / `runWithFailure` / `Db.attempt` / `Tx.withSavepoint` / `Retry.withRetry*` / `RawSql.runWithAllow` | 中で投げた物が外側の catch を素通りしうる | `run` の直下で拾い、`run` を抜けてから同じ物を投げ直す（値にしない） |
| `Tx.rollback` | `Unit` | `Bool`（成功したか） |
| 新しい `Pool.evict(pool, conn)` | 無し | 自前で接続を借りて handler を書く利用側（nextcms の RequestTx）向け。evict だけで close しない |
| 新しい `Db.catchAll(thunk): Result[Throwable, a]` | 無し（private） | 公開。handler の本体を包む利用側向け |
| 新しい `Sqlfx.CommitOutcomeUnknown` | 無し | COMMIT の最中の fatal に `addSuppressed` で付く marker の例外 |

型の上で変わるのは `Tx.rollback` だけで、他は振る舞いの変化と足した物。

### 2.7 テスト計画

#### fatal を決定的に起こす方法

- **thunk / onBegin / 利用側の handler の内側:** `throw new OutOfMemoryError("injected")`。コンストラクタで作るだけでメモリは使わない
- **handler の本体（`Jdbc.*` の中）と COMMIT / ROLLBACK:** `HikariConfig.setDataSource` に、本物の `PGSimpleDataSource` の接続を `java.lang.reflect.Proxy` で包んで返す `DataSource` を渡し、`Pool.Pool(HikariDataSource)` で組む。Flix の `new InvocationHandler` / `new DataSource` で組める事と HikariCP が受ける事は spike S3 で確かめた（scratchpad の `SpikeFaulty.flix` が下敷き）

| SQL の marker / 設定 | Proxy がすること |
|---|---|
| `/* inject: fatal-on-prepare */` | `prepareStatement` で `OutOfMemoryError` |
| `/* inject: fatal-after-execute */` | 本物の `executeUpdate` / `executeQuery` を走らせた後で `OutOfMemoryError` |
| `/* inject: driver-runtime-after-execute */` | 同じ位置で、stack trace の先頭を `org.postgresql.core.v3.QueryExecutorImpl` の frame にした `IllegalStateException`（pgjdbc の中から出た物として扱われる形） |
| `/* inject: runtime-after-execute */` | 同じ位置で素の `IllegalStateException`（stack trace は Proxy の物のまま） |
| `failSetAutoCommit` | `setAutoCommit(false)` で `SQLException` |
| `failRollback` | `rollback()` で `SQLException` |
| `fatalOnCommit` | `commit()` で `OutOfMemoryError` |

Proxy は本物の接続への呼び出しを記録し、「evict の後に ROLLBACK / setAutoCommit / clearWarnings が 0 回」を assert に入れる。置き場は `test/Pg/FaultyDataSource.flix`。

#### `test/Pg/TestPoolFatal.flix`（大きさ 1・借り待ち 300 ms のプール）

どれも 1 assert で `(投げ直された例外の class, 表の row の数, active, 次の借りの結果, 次の接続の backend pid が同じか, evict の後の本物の接続への protocol の呼び出し)` を見る。

| # | 場面 | 期待 |
|---|---|---|
| 1 | thunk で INSERT → `throw OutOfMemoryError` | OOM、0 row、active 0、次は Ok、pid は別、呼び出し 0 |
| 2 | `fatal-after-execute` の INSERT | 同上 |
| 3 | `fatal-on-prepare` の SELECT が Tx の最初の文 | 同上（evict → close の手順の spike では NPE にすり替わった件） |
| 4 | onBegin で `throw OutOfMemoryError` | 同上（同） |
| 5 | 利用側の handler の内側の `Db.guard` の中で INSERT → fatal | OOM が抜け、**active 1、次は Timeout**（2.1 の f。直らない事の記録） |
| 6 | `Db.attempt(() -> Tx.withSavepoint("sp", () -> Db.guard(() -> { INSERT; OOM })))` | 1 と同じ |
| 7 | 6 から `Db.guard` を外す | 1 と同じ（0.5.0 は active 1） |
| 8 | 7 の OOM を `RuntimeException` に | 投げ直さない、`Other`、0 row、active 0、pid は同じ（0.5.0 は active 1） |
| 9 | 7 の外側の `RawSql.runWithAllow` を thunk の中に置く | 1 と同じ |
| 10 | SQL を出さない thunk で fatal | OOM、active 0、total 0 |
| 11 | `fatalOnCommit` | OOM、suppressed に `CommitOutcomeUnknown`、active 0、pid は別 |
| 12 | `driver-runtime-after-execute` | 投げ直さない、`Other`、0 row、active 0、pid は別（evict） |
| 13 | `runtime-after-execute` | 投げ直さない、`Other`、0 row、active 0、**pid は同じ**（ROLLBACK して返す） |
| 14 | thunk で `RuntimeException` | 投げ直さない、`Other`、0 row、active 0、pid は同じ |
| 15 | `failSetAutoCommit` | `Other`、active 0、次は Ok（2.1 の k。0.5.0 は active 1） |
| 16 | `failRollback` で thunk が業務の `Err` | `Err` が返る、active 0、pid は別 |
| 17 | `Retry.withRetry(3, ...)` の中で 1 回目は Transient、2 回目で 1 と同じ | OOM、thunk を呼んだ回数 2、active 0 |
| 18 | `Pool.withConnection` の thunk で fatal / `fatal-after-execute` | 1 と同じ |
| 19 | `Pool.withConnection` の thunk で `RuntimeException` | `Other`、active 0（0.5.0 は例外のまま抜けて active 1） |
| 20 | `OutOfMemoryError` を `CompletionException` で包んで投げる | 1 と同じ（cause の連鎖） |
| 21 | 2 を 20 回続ける | 全部 OOM、NPE 0（spike と同じ数え方） |

今の `TestPoolLeaks` の全テストは期待を変えずに通る事（e の記録のテストも含む）。

#### DB 無し（`test/Db/`）

| テスト | 見る物 |
|---|---|
| `TestFatal.flix` | `isFatal` の表（OOM / InternalError / StackOverflowError / RuntimeException / cause に OOM / 深さ 9 の cause に OOM）。「pgjdbc の中から出た」の判定の表 |
| `TestCatchNesting.flix` | 2.2 の表を再現する（handler の本体の try、`resume` を try の中で呼ぶ形、D の「`run` の直下で拾って外で投げ直す」形）。0.75.3 で回し、0.76.0 は nextcms の worktree で 1 回 |

---

## 3. 互換とバージョン

**0.6.0 にする。** README の「0.x の間は minor で壊れうる」に従う。

- `Tx.rollback` の型が変わる
- `Pool.withConnection` 系で、例外で抜けていた物が `DbErr.other` になる
- 字句の直し（`/* */` と dollar quote）で、WITH の無い query でも `/* project_id */` のようにコメントでだけ scope のカラムを書いた query が止まる。nextcms の `.q` に該当が無い事を N1 の `make gen` で確かめる
- WITH を含む query は 0.5.0 で書けなかったので、厳しい scope の規則（1.8 の決め 2）で既存の `.q` は止まらない
- 生成物の形は変わらないので、`Codegen.version()` は `"10"` のまま
- `Migrate` の checksum の計算は変えない（`Migrate.checksum` は `SqlTokens` を使っていない事を確かめた）。0.5.0 と 0.6.0 で、nextcms の `migrations/*.sql` 全部の checksum が同じになるテストを置く（N1）

README（英語と日本語の両方）に足す物:

- 「The `.q` file and the scope rules」に「CTE」の節: 入れる形・断る形の表（1.2）、書き込みの CTE は `DbWrite`、scope は文ごとで WITH を含む query は厳しい規則、`// unscoped: in <name>`、`gen --statements`
- 「Shapes that break, measured」の表と図: 2.2 の表、2.1 の b / c / d / g / h / i / j / k が消えて e / f が残る事、f を塞ぐ `guardTx` の形は利用側で書く事とその前提、`Tx.withTx` をプールの接続で使わない事
- 「Upgrading from 0.5.0 to 0.6.0」: (1) `Tx.rollback` が `Bool`、(2) `Pool.withConnection` の thunk の `RuntimeException` が `DbErr.other`、(3) `Db.isFatal` が cause の連鎖を見る、(4) 自前の SqlRead / SqlWrite の handler を書いているなら本体を `Db.catchAll` で包み、fatal なら `Pool.evict` してから投げる、(5) `/* */` と dollar quote の中の語を scope の検査が数えなくなった、(6) `INSERT ... RETURNING` が書き込み先の表だけで解決される
- `flix.toml` の `version = "0.6.0"`

---

## 4. nextcms 側の追従

順に、前の段が main に入ってから次に進む。

| # | すること | 消せる物 | 確かめる事 |
|---|---|---|---|
| N1 | `flix.toml` の sqlfx を 0.6.0 に上げ、`flix_db` の checkout を同じ tag に合わせ、`make gen` | 無し | `src/generated/sql/` に差分が出ない。`migrations/*.sql` の checksum が 0.5.0 の計算と同じ（テストで全ファイル）。`scripts/check-sqlfx-version.sh` が通る。`TestTxLeakPg` が全部通る |
| N2 | fatal まわり: (a) `docs/architecture/runtime.md` の 91–92 line の「残る穴」を、塞がった物（d / g / j）と残る物（f を `guardTx` で塞いでいる事）に書き直す。(b) RequestTx の自前の handler の本体を `Db.catchAll` で包み、fatal なら `Pool.evict` → 状態を Broken → 投げ直す。(c) `ContentEntries.aggregatingResult` の中の自前の `run`（`StatementTimeout.withTimeout`、`HeavyQuery.limited` が handler を張る所）の直下に catch を置き、`run` の外で投げ直す。(d) fatal の suppressed に `Sqlfx.CommitOutcomeUnknown` があればリクエストの line に `db.tx.outcome: unknown` | 無し。`returningConnection` と `guardTx` は残す（2.1 の f を塞いでいる。sqlfx は f を塞がない） | `TestTxLeakPg` が変更無しで通る。`aggregatingResult` の中で外の handler に op を投げた後に `RuntimeException` を投げるテストで接続が返る |
| N3 | 接続の設定: `DbConfig.withTimeouts` の `options` に `client_connection_check_interval` を足し、JDBC の URL に pgjdbc の `ApplicationName`（配備の色ごと。`nextcms-blue` / `nextcms-green`）を付ける | 無し | evict や JVM の停止で相手のいなくなった接続の長い文を PG が打ち切る事。`pg_stat_activity` で色ごとに接続を数えられる事 |
| N4 | `queries/entries.q` の `upsertContent` と `fillMissingField` を 1.3 の形に書き換え、`upsertContents` を足し、`touchEntry` / `touchEntries` を消す。`ContentEntries.writeContent` と `ContentTypes` の fill の 2 か所から touch の呼び出しを消し、入れ子の fill（`fillNested` の繰り返し）は `upsertContents` の 1 回にする | `touchEntry` / `touchEntries`、entries.q の WhyNot（CTE を読めない） | 公開の Tx が entries と entry_contents を lock する順を読んで書き留める。fill と同じ entry の公開を並行に走らせる実 PG のテストを 1 件（deadlock しない事）。今の touch のテストがそのまま通る事 |
| N5 | entry-touch の check を 1 段にする。`make gen` に `--statements src/generated/sql/statements.json` を足して commit し（`gen-check` と `check-generated` が鮮度を見る）、`bin/cms entry-touch`（`go/internal/entrytouch`）はその JSON だけを読んで「`entry_contents` の `data` を `columns` か `conflictSet` に持つ文を含む query は、同じ query に `target = entries` で `updated_at` を書く文も含む」を検査する。flixlint の `entry-touch` rule と `contentDataWriters` / `entryTouchers` を消す | flixlint の rule と 2 つの一覧、Go の正規表現の SQL の読み | 壊して落ちる事を 1 回見る（touch の CTE を消した `.q` で exit 1、メッセージに直し方）。AGENTS.md の entry-touch の項と `docs/architecture/lint.md` の 47–52 line を 1 段の形に書き直す |

N4 と N5 は途中の状態で check が落ちるので 1 つの commit にする。N2 / N3 と N4 / N5 は互いに依らない。

**migration には触れない。** 変わるのは `queries/*.q`、`src/generated/sql/`（生成物と `statements.json`）、Flix / Go のコードと `DbConfig` の接続の設定だけで、`migrations/*.sql` は `make gen` と `make migrate` が読むだけ。`entries` / `entry_contents` の DDL も変えない。N1 の checksum のテストと、N4 の commit の前の `git diff --stat -- migrations/` が空である事で確かめる。

---

## 5. 仕事の割り振りと commit の単位

実装とテストは Mac mini で行う（PostgreSQL が要るテストはそちら）。sqlfx 側は `make test-unit`（DB 無し）を commit ごとに、`make test-pg` と `make test-examples` を PG に触る commit ごとに回す。

| # | commit | 中身 | 回す物 |
|---|---|---|---|
| C1 | 実測を test にする | `test/Db/TestCatchNesting.flix`、`test/Pg/FaultyDataSource.flix`、evict の手順ごとの結果を assert する Pg テスト（spike S2x の表）。製品のコードは変えない | test-unit、test-pg。0.76.0 の分は nextcms の worktree に同じテストを置いて 1 回 |
| C2 | `isFatal` と `catchAll` | `Db.isFatal` の cause の連鎖、`Db.catchAll` の公開、「pgjdbc の中から出た」の判定。`test/Db/TestFatal.flix` を先に書く | test-unit |
| C3 | D の catch | `DbError.runWithKind` / `Tx.withSavepoint` / `Retry.withRetry*` / `RawSql.runWithAllow` の `run` の直下の catch。2.7 の 7〜9 を先に書く | test-unit、test-pg |
| C4 | Tx の入口 | `open()` の順、A / B / C、evict だけ、`Tx.rollback` の `Bool`、`CommitOutcomeUnknown`、`Pool.evict`、`Pool.withConnection*` / `Jdbc.withConnection` / `Tx.withTx`。`test/Pg/TestPoolFatal.flix` | test-unit、test-pg |
| C5 | README の fatal の節 | 英語と日本語 | 無し |
| C6 | 字句 | `SqlTokens` と `QParser` の `/* */` と dollar quote。テストを先に書く | test-unit |
| C7 の前 | 計測 | nextcms の `queries/*.q` 全部に、(1) 字句の直しの後の今の検査、(2) `touchedTables` に `USING` とカンマの続きを足した検査、(3) R1〜R4 を当て、それぞれ止まる件数と query 名を報告する。WITH の無い query に何を当てるかはこの数で決める | gen を nextcms の queries に当てるだけ |
| C7 | `QCte.split` | WITH の判定、`Unit` の位置。`test/Q/TestQCte.flix` を先に書く | test-unit |
| C8 | CTE の型付け | `QResolve` の CTE、`writes`、`SameTableWrittenTwice`、`RETURNING` の source、slot の文、`QResolve.describe`、QLint の未使用の CTE | test-unit |
| C9 | scope | 文の単位、R1〜R4、`// unscoped: in`、メッセージ | test-unit |
| C10 | 生成と実 PG | `TestCodegen` / `TestGen` の CTE の件、`gen --statements`、`examples/blog` の CTE の query と生成物と Pg テスト | test-unit、test-pg、test-examples |
| C11 | 0.6.0 | README の CTE の節と移行の節、`flix.toml` の version、`make pkg` | 全部。push したら CI を見る |

nextcms 側（N1〜N5）は sqlfx の 0.6.0 の tag を打った後に、4 節の順で行う。Flix に効く段は本体が `make test-pg` を回してから commit する。

---

## 6. 迷った事と選んだ理由

| 迷った事 | 選んだ物 | 理由 |
|---|---|---|
| fatal をいつ投げ直すか | 拾った所で evict し、その場で投げ直す | 値にすると、出口が走らない経路（Tx の外で受けた非再開の effect、2.1 の e）で fatal が消える。evict 済みなら、投げ直した例外が後始末を飛ばしても漏れない |
| Tx ごとの fatal の slot（`ThreadLocal`） | 持たない | 置き場が `System.getProperties()` しか無く、出口が走らないと slot が残って Tx の外の `Db.guard` が OOM を飲み込む（spike S4-stale） |
| 2.1 の f を sqlfx で塞ぐか | 塞がない。nextcms は `guardTx` を残す | 塞ぐには fatal を値にする必要があり、利用側が Tx の外で非再開の effect を受ける形を sqlfx は禁じられない |
| evict の後に close を呼ぶか | 呼ばない | close は ROLLBACK を送るか、HikariCP の中で NPE になって fatal がすり替わる |
| fatal でない例外を handler の本体で拾った時に evict するか | pgjdbc の中から出た物だけ | 毎回 evict すると sqlfx 側の変換の失敗でも接続を作り直す。protocol に触っていない失敗は ROLLBACK で足りる |
| `WITH RECURSIVE` / 入れ子の WITH / 表と同じ名前の CTE | 断る | 型の規則か scope の単位を新しく決める事になり、要る所が今無い |
| 同じ表を 2 つの文で書く query | 断る | 片方が黙って効かない（PG 7.8.4、実測） |
| scope の規則 | WITH を含む query は最初から厳しく、WITH の無い query は計測してから | WITH を含む query は 0.5.0 に無いので止まる物が無い。WITH の無い query に当てると既存の query が止まる見込みがある |
| `fillNested` | 一括の 1 文（`upsertContents`） | row ごとの 1 文は、公開の Tx と lock の順が逆になって deadlock する（実測） |
| entry-touch の check が SQL をどう読むか | ジェネレータが書いた `statements.json` を Go が読む | SQL のパーサを 2 つ持たない |
| バージョン | 0.6.0 | `Tx.rollback` の型、`withConnection` の例外の扱い、字句の直しで止まる query がある |

---

## 7. 残る危険

- **2.1 の e と f は直らない。** 利用側が thunk の中に自分の handler を張り、その内側で投げた物（f は `Db.guard` の fatal）は、ライブラリの catch に届かない。nextcms は `guardTx` で f を塞いでいる。e は README の決まりのまま
- **`Pool.withConnection` の中の `Tx.withTx` / `Jdbc.runWithConnection` の handler の本体の fatal** は、外の `Pool.withConnection` の後始末が飛んで漏れうる。README で `Pool.withLazyTx*` に向ける
- **WITH の無い query の scope の粗さ**（副問い合わせ、SELECT リストだけ、`USING`、カンマの続き、INSERT ... SELECT の読み元）は、C7 の前の計測の後に決めるまで残る。RLS が後ろにある
- **COMMIT の最中の fatal では、COMMIT が PG に届いたか分からない。** marker（suppressed）を付けて投げるだけで、結果は分からないまま
- **「pgjdbc の中から出た」の判定は class 名と stack trace の先頭で見ている。** pgjdbc が内部の例外を別の包み方に変えると判定が外れ、protocol の途中の接続を ROLLBACK で返す事になる。HikariCP の `08` の evict が後ろの網
- **catch の届く位置は Flix のコンパイラのバージョンで変わりうる。** 0.75.3 と 0.76.0 では同じ結果だった。コンパイラを上げるたびに `TestCatchNesting` と `TestPoolFatal` を回す
- **evict の後の物理接続の close は HikariCP の中で非同期。** 閉じるまでの間、PG 側の Tx が残る。N3 の `client_connection_check_interval` と既にある `idle_in_transaction_session_timeout` が後ろの網
- **touch を 1 文にすると、`upsertContent` の返す数の意味が変わる**（`entry_contents` の数 → `entries` の数）。N4 で query の doc コメントに書く
- **fill と公開の lock の順**は N4 の並行のテストで確かめるまで分からない。公開の Tx が entries を先に lock するなら、`upsertContents` の 1 文でも deadlock しうる。その時は fill の Tx の最初に対象の entries を `SELECT ... ORDER BY id FOR UPDATE` で lock する形を足す
