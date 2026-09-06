-- migrate のテスト用。本体の test/Pg/TestMigrate.flix が当てる
CREATE TABLE sqlfx_mig_test (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL
);
INSERT INTO sqlfx_mig_test (name) VALUES ('first');
