.PHONY: check test test-unit test-pg gen gen-check test-examples db-up db-down pkg release

check:
	bin/flix check

# フル: DB 無し → 実 PG → examples の順に回す
test: test-unit test-pg test-examples

# DB 無しのテスト。build/unit/ に src/ と test/（Pg を除く）を写した作業用プロジェクトを作って、そこで回す。
# 元のファイルには触らないので、VSCode の LSP も、途中で止めたときの状態も影響を受けない。
# WhyNot: test/Pg/ を test/ の外に置かないのは、VSCode の Flix 拡張が src/ と test/ しか LSP に渡さないから。
# rsync なのは、差分だけ写して 2 回目以降を速くするため。lib/ は build/unit/ に残るので Maven の取得も 1 回で済む。
UNIT_DIR = build/unit

test-unit:
	mkdir -p $(UNIT_DIR)
	cp flix.toml $(UNIT_DIR)/flix.toml
	rsync -a --delete src/ $(UNIT_DIR)/src/
	rsync -a --delete --exclude Pg test/ $(UNIT_DIR)/test/
	ln -sfn $(CURDIR)/examples $(UNIT_DIR)/examples
	cd $(UNIT_DIR) && $(CURDIR)/bin/flix test

# 実 PostgreSQL に当たるテスト。コンテナを立て、test/ を全部（test/Pg/ 込み）回し、終わったらコンテナを止める。
# WhyNot: flix test にはテストの絞り込みが無いので、DB 無しの分も一緒に走る。
PG_ENV = SQLFX_TEST_DSN=jdbc:postgresql://127.0.0.1:5432/sqlfx SQLFX_TEST_USER=flix SQLFX_TEST_PASSWORD=flix

test-pg:
	docker compose up -d --wait
	$(PG_ENV) bin/flix test; status=$$?; docker compose down -v; exit $$status

# examples/blog は独立した Flix プロジェクト。本体を写して（vendor）DB 無しと実 PG のテストを回す
test-examples:
	$(MAKE) -C examples/blog test

# examples/blog の migrations と .q から Flix を生成する
gen:
	$(MAKE) -C examples/blog gen

# 生成物が最新か（書かない。CI 用）
gen-check:
	$(MAKE) -C examples/blog gen-check

# 手動で PG を触りたいとき用
db-up:
	docker compose up -d --wait

db-down:
	docker compose down -v

# ---- 配布 ----
# ライブラリだけを .fpkg に詰める。Main.flix（gen / migrate の CLI）と Q/ の生成器は入れない。
# WhyNot: src/ をそのまま build-pkg しないのは、利用側の main と `def main` が、生成器の Schema モジュールが
# 利用側の同名モジュールと衝突するため。生成器は利用側からも `bin/flix run -- gen` でこのリポジトリの main を使う。
PKG_DIR = build/sqlfx

pkg:
	rm -rf $(PKG_DIR)
	mkdir -p $(PKG_DIR)/src/Q
	cp flix.toml $(PKG_DIR)/flix.toml
	cp -R src/Db src/Time src/Uuid $(PKG_DIR)/src/
	cp src/Q/Fragment.flix $(PKG_DIR)/src/Q/
	cd $(PKG_DIR) && $(CURDIR)/bin/flix build-pkg
	@ls -l $(PKG_DIR)/artifact/

# GitHub の release に .fpkg を付ける。利用側は flix.toml の [dependencies] に "github:ababup1192/sqlfx" = "<version>" と書く。
# version は flix.toml の [package] version と揃える（Flix は tag v<version> の release から .fpkg を取る）
VERSION = $(shell sed -n 's/^version *= *"\(.*\)"/\1/p' flix.toml)

release: pkg
	gh release create v$(VERSION) $(PKG_DIR)/artifact/sqlfx.fpkg $(PKG_DIR)/artifact/flix.toml --title "v$(VERSION)" --notes "sqlfx $(VERSION)"
