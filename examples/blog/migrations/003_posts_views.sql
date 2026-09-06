-- 閲覧数を後から足した migration の例
ALTER TABLE posts ADD COLUMN views INTEGER NOT NULL DEFAULT 0;
