.PHONY: check test test-unit test-pg db-up db-down

check:
	bin/flix check

# フル: DB 無し → 実 PG の順に回す
test: test-unit test-pg

# DB 無しのテスト。test/ だけを回す
test-unit:
	bin/flix test

# 実 PostgreSQL に当たるテスト。コンテナを立て、test-pg/ を test/Pg/ に写して回し、終わったら消してコンテナも止める。
# WhyNot: flix test にはテストの絞り込みが無く、ファイル指定だと Maven 依存が乗らない。
# なので PG テストは test/ の外に置き、回すときだけ test/ へ写す（test/ の分も一緒に走る）。
PG_ENV = FLIX_DB_TEST_DSN=jdbc:postgresql://127.0.0.1:5432/flix_db FLIX_DB_TEST_USER=flix FLIX_DB_TEST_PASSWORD=flix

test-pg:
	docker compose up -d --wait
	rm -rf test/Pg && cp -R test-pg test/Pg
	$(PG_ENV) bin/flix test; status=$$?; rm -rf test/Pg; docker compose down -v; exit $$status

# 手動で PG を触りたいとき用
db-up:
	docker compose up -d --wait

db-down:
	docker compose down -v
