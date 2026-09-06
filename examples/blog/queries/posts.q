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

query deletePostsOfUser(userId: Int64) -> exec {
    DELETE FROM posts WHERE user_id = :userId
}
