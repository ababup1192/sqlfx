# flix_db

Flix の PostgreSQL 向け DB ライブラリ。SQL は 1 ミリも抽象せず、
SQL 文の *間*（DB 境界・エラーの捌き方・トランザクション・N+1・テスト）を
代数的エフェクトで型に出す。設計の全体像は [docs/design.md](docs/design.md)、
実装の順番は [PLAN.md](PLAN.md)。

層0（`SqlValue` / `Row` / `Decoder` / `SqlRead` / `SqlWrite` / エラー 2 分類 / テストハンドラ / JDBC ハンドラ / `withRetry` / `withTx`）が入っている。次は層1（`.q` と codegen）。API は [docs/layer0.md](docs/layer0.md)。

## 使い方

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。
JDK が PATH に要る。

```bash
make check    # 型検査
make test     # フル（test-unit → test-pg）
make test-unit # DB 無しのテスト（test/）
make test-pg  # 実 PG のテスト。docker compose で PostgreSQL 16 を立て、test-pg/ を回し、終わったら止める
make db-up    # 手動で PG を触りたいとき
make db-down  # PostgreSQL を落としてデータも消す
```

`bin/flix` は `--Xsubeffecting=lambdas` を付けて呼ぶ。VS Code の Flix 拡張にも同じフラグが要り、
`.vscode/settings.json` の `flix.extraFlixArgs` で渡している。

## ディレクトリ

```
docs/design.md            設計概要（正）
docs/flix-conventions.md  Flix を書くときの決まり
PLAN.md                   実装プラン
src/Db/                   ライブラリ本体（モジュールはトップレベルに平ら）
test/                     src と同じ構成。DB 無しで回る。test/Example/ が使い方の見本
test-pg/                  実 PG が要るテスト。make test-pg が test/Pg/ へ写して回す（flix test に絞り込みが無いため）
```

Flix の書き方の決まりは [docs/flix-conventions.md](docs/flix-conventions.md)、
コードの流儀は [AGENTS.md](AGENTS.md) を参照。
