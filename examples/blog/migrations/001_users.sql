-- users: 投稿者。分岐したい制約には名前を付ける（違反が制約名で返る）
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT,
    role TEXT NOT NULL DEFAULT 'member',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT users_email_key UNIQUE (email),
    CONSTRAINT users_name_length CHECK (length(name) <= 50)
);
