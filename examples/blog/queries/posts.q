// posts.q: 記事のクエリ

query postsByUsers(ids: List[Int64]) -> many keyed(user_id) {
    SELECT id, user_id, title, published, views FROM posts WHERE user_id = ANY(:ids) ORDER BY id
}

query postWithAuthor(id: Int64) -> one {
    SELECT p.id, p.title, p.body, p.tags, u.name AS author_name, u.email AS author_email
    FROM posts AS p
    JOIN users AS u ON u.id = p.user_id
    WHERE p.id = :id
}

query publishedPosts(limit: Int64) -> many with filter: Pred[posts] {
    SELECT id, user_id, title, views FROM posts WHERE published AND {filter} ORDER BY views DESC, id LIMIT :limit
}

query insertPost(userId: Int64, title: String, body: String, tags: List[String]) -> one {
    INSERT INTO posts (user_id, title, body, tags) VALUES (:userId, :title, :body, :tags) RETURNING id
}

query publishPost(id: Int64) -> exec {
    UPDATE posts SET published = TRUE WHERE id = :id
}

query addView(id: Int64) -> exec {
    UPDATE posts SET views = views + 1 WHERE id = :id
}

// 編集フォーム用。SET の中身は呼ぶ側が Changes で組む。空なら DB に出さず 0
query updatePost(id: Int64) -> exec with changes: Changes[posts] {
    UPDATE posts SET updated_at = now(), {changes} WHERE id = :id
}

query deletePostsOfUser(userId: Int64) -> exec {
    DELETE FROM posts WHERE user_id = :userId
}

// max は行が無いと NULL を返す。! で NOT NULL を主張しているので、記事の無い人を渡すと decodeError で落ちる（黙って 0 にはならない）
query topViewsOfUser(userId: Int64) -> one {
    SELECT max(views)::bigint! AS top FROM posts WHERE user_id = :userId
}

// 記事を消し、書き手の updated_at を同じ 1 文で動かす（書き込みの CTE）。返すのは updated_at を動かした書き手の id。
// 2 つの文は別の表を書く（同じ表を 2 つの文で書くと、PG は片方しか効かせないので生成器が断る）
query deletePostTouchingAuthor(id: Int64) -> many {
    WITH gone AS (DELETE FROM posts WHERE id = :id RETURNING user_id)
    UPDATE users SET updated_at = now() WHERE id = ANY(ARRAY(SELECT user_id FROM gone)) RETURNING id
}
