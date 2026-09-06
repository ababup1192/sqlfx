-- sqlfx:no-transaction
CREATE INDEX CONCURRENTLY IF NOT EXISTS sqlfx_mig_test_name_idx ON sqlfx_mig_test (name);
