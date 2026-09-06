.PHONY: vendor gen gen-check check test test-unit test-pg db-up db-down

FLIX = ../../bin/flix
COMPOSE = docker compose -f ../../docker-compose.yml
PG_ENV = SQLFX_TEST_DSN=jdbc:postgresql://127.0.0.1:5432/sqlfx SQLFX_TEST_USER=flix SQLFX_TEST_PASSWORD=flix

# sqlfx 本体を src/sqlfx/ に写す（flix.toml がローカル依存を指せないため）
vendor:
	rm -rf src/sqlfx && mkdir -p src/sqlfx && cp -R ../../src/Db ../../src/Q src/sqlfx/

# migrations と queries/*.q から src/Gen/ を作り直す（生成器は本体の main）
gen:
	cd ../.. && bin/flix run -- gen examples/blog/migrations examples/blog/queries examples/blog/src/Gen

# 生成物が最新か（書かない。本体の make test-unit でも同じ検査が走る）
gen-check:
	cd ../.. && bin/flix run -- gen --check examples/blog/migrations examples/blog/queries examples/blog/src/Gen

check: vendor
	$(FLIX) check

# フル: DB 無し → 実 PG
test: test-unit test-pg

# DB 無しのテスト。build/unit/ に src/ と test/（Pg を除く）を写した作業用プロジェクトを作って、そこで回す（ルートと同じ方式）
UNIT_DIR = build/unit

test-unit: vendor
	mkdir -p $(UNIT_DIR)
	cp flix.toml $(UNIT_DIR)/flix.toml
	rsync -a --delete src/ $(UNIT_DIR)/src/
	rsync -a --delete --exclude Pg test/ $(UNIT_DIR)/test/
	ln -sfn $(CURDIR)/migrations $(UNIT_DIR)/migrations
	ln -sfn $(CURDIR)/queries $(UNIT_DIR)/queries
	cd $(UNIT_DIR) && $(CURDIR)/../../bin/flix test

# 実 PostgreSQL に当たるテスト。コンテナを立て、test/ を全部回し、終わったらコンテナを止める
test-pg: vendor
	$(COMPOSE) up -d --wait
	$(PG_ENV) $(FLIX) test; status=$$?; $(COMPOSE) down -v; exit $$status

db-up:
	$(COMPOSE) up -d --wait

db-down:
	$(COMPOSE) down -v
