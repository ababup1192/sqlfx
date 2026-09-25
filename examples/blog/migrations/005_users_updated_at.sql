-- 書き手の更新日時。書き込みの CTE（記事を消して書き手の updated_at を動かす）の例で使う
ALTER TABLE users ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
