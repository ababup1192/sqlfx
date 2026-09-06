-- 編集日時。部分更新（Changes）の例で SET updated_at = now() と並べる
ALTER TABLE posts ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
