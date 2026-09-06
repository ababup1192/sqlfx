// users.q: 投稿者のクエリ

query findUser(id: Int64) -> one {
    SELECT id, name, email, role FROM users WHERE id = :id AND deleted_at IS NULL
}

query findUserByEmail(email: String) -> one {
    SELECT id, name, email, role FROM users WHERE email = :email
}

query searchUsers(limit: Int64) -> many
    with filter: Pred[users], order: Order[users]
{
    SELECT id, name, email, role FROM users
    WHERE deleted_at IS NULL AND {filter}
    {order}
    LIMIT :limit
}

query insertUser(name: String, email: String, role: String) -> one {
    INSERT INTO users (name, email, role) VALUES (:name, :email, :role) RETURNING id
}

query renameUser(id: Int64, name: String) -> exec {
    UPDATE users SET name = :name WHERE id = :id
}

query softDeleteUser(id: Int64) -> exec {
    UPDATE users SET deleted_at = now() WHERE id = :id AND deleted_at IS NULL
}

query countUsers() -> one {
    SELECT count(*)::bigint AS total FROM users WHERE deleted_at IS NULL
}
