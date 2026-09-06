///
/// 同じユースケースを、.q を使わず生 SQL をインラインで書いた版。層0 だけでどう書けるかの見本。
/// Blog.flix（生成コード版）と見比べるための物なので、機能は同じにしてある。
///
mod BlogRaw {

    use SqlValue.SqlValue
    use Decoder.Decoder

    ///
    /// 投稿者。
    ///
    /// - `id`: 主キー
    /// - `name`: 表示名
    /// - `email`: 未設定なら None
    ///
    pub type alias User = { id = Int64, name = String, email = Option[String] }

    ///
    /// 記事の見出し。
    ///
    /// - `id`: 主キー
    /// - `userId`: 投稿者
    /// - `title`: 題名
    ///
    pub type alias PostHead = { id = Int64, userId = Int64, title = String }

    ///
    /// 投稿者と、その人の記事。
    ///
    pub type alias UserWithPosts = { user = User, posts = List[PostHead] }

    ///
    /// users の列を User に組む。生 SQL 版は自分でデコーダを書く。
    ///
    pub def userDecoder(): Decoder[User] =
        forA (
            id <- Decoder.int64("id");
            name <- Decoder.str("name");
            email <- Decoder.opt(Decoder.str("email"))
        ) yield { id = id, name = name, email = email }

    pub def postHeadDecoder(): Decoder[PostHead] =
        forA (
            id <- Decoder.int64("id");
            userId <- Decoder.int64("user_id");
            title <- Decoder.str("title")
        ) yield { id = id, userId = userId, title = title }

    ///
    /// 投稿者を登録して id を返す（RETURNING）。
    ///
    pub def registerUser(user: { name = String, email = String }): Option[Int64] \ DbWrite + RawSql =
        Sql.executeReturningOneAs(Decoder.int64("id"), "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", List#{SqlValue.Str(user#name), SqlValue.Str(user#email)})

    ///
    /// email で 1 人取る。
    ///
    pub def findUserByEmail(email: String): Option[User] \ DbRead + RawSql =
        Sql.fetchOneAs(userDecoder(), "SELECT ${Decoder.selectClause(userDecoder())} FROM users WHERE email = $1", List#{SqlValue.Str(email)})

    ///
    /// 名前が prefix で始まる投稿者を名前順で。生 SQL 版では動的な条件を文字列で組むことになる。
    /// SELECT 句はデコーダから組むので、列名を書くのはデコーダの 1 回だけ。
    ///
    pub def activeUsersNamed(search: { prefix = String, limit = Int64 }): List[User] \ DbRead + RawSql =
        let condition = if (search#prefix == "") "" else " AND name LIKE $2";
        let params = if (search#prefix == "") List#{SqlValue.Int64(search#limit)} else List#{SqlValue.Int64(search#limit), SqlValue.Str(search#prefix + "%")};
        Sql.fetchAs(userDecoder(), "SELECT ${Decoder.selectClause(userDecoder())} FROM users WHERE deleted_at IS NULL" + condition + " ORDER BY name LIMIT $1", params)

    ///
    /// 投稿者と記事を 2 クエリで取る。
    ///
    pub def usersWithPosts(limit: Int64): List[UserWithPosts] \ DbRead + RawSql =
        let users = Sql.fetchAs(userDecoder(), "SELECT ${Decoder.selectClause(userDecoder())} FROM users WHERE deleted_at IS NULL ORDER BY id LIMIT $1", List#{SqlValue.Int64(limit)});
        let posts = Sql.fetchAs(postHeadDecoder(), "SELECT ${Decoder.selectClause(postHeadDecoder())} FROM posts WHERE user_id = ANY($1) ORDER BY id", List#{SqlValue.Int64Array(List.map(user -> user#id, users))});
        Preload.attach({ parents = users, parentKey = user -> user#id, children = posts, childKey = post -> post#userId })
            |> List.map(pair -> { let (user, theirs) = pair; { user = user, posts = theirs } })

    ///
    /// 記事を書いて公開する。影響行数を返す。
    ///
    pub def writePost(post: { author = Int64, title = String, tags = List[String] }): Int32 \ DbWrite + RawSql =
        Sql.execute("INSERT INTO posts (user_id, title, tags, published) VALUES ($1, $2, $3, TRUE)", List#{SqlValue.Int64(post#author), SqlValue.Str(post#title), SqlValue.StrArray(post#tags)})

    ///
    /// 記事の数。式の列は selectExpr で `count(*)::bigint AS n` を SELECT 句に出し、n を読む。
    ///
    pub def countPosts(): Int64 \ DbRead + RawSql =
        let count = Decoder.selectExpr("count(*)::bigint", Decoder.int64("n"));
        Sql.fetchOneAs(count, "SELECT ${Decoder.selectClause(count)} FROM posts", Nil) |> Option.getWithDefault(0i64)

    ///
    /// 投稿者を退会させる。記事を消してから soft delete。1 つの Tx で呼ぶこと。
    ///
    pub def removeUser(id: Int64): Bool \ DbWrite + RawSql =
        discard Sql.execute("DELETE FROM posts WHERE user_id = $1", List#{SqlValue.Int64(id)});
        Sql.execute("UPDATE users SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL", List#{SqlValue.Int64(id)}) > 0

}
