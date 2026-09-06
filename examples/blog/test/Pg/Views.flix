///
/// 実 PG のテストで期待値と比べるための「名前付きの見え方」。
/// 生成される行レコードは Eq を持たない（Flix のレコードは比較も表示もできない）ので、
/// 比べたい列だけを enum に写し、作るときはレコードで名前を付ける。
///
mod Views {

    pub enum UserView with Eq, Order, ToString {
        case UserView(Int64, String, Option[String], String)
    }

    ///
    /// 期待値を名前付きで作る。
    ///
    pub def user(v: { id = Int64, name = String, email = Option[String], role = String }): UserView =
        UserView.UserView(v#id, v#name, v#email, v#role)

    ///
    /// 生成された行から。findUser / findUserByEmail / searchUsers の行はどれも同じ形。
    ///
    pub def ofUserRow(row: { id = Int64, name = String, email = Option[String], role = String }): UserView =
        user({ id = row#id, name = row#name, email = row#email, role = row#role })

    pub enum PostView with Eq, Order, ToString {
        case PostView(Int64, Int64, String, Bool, Int32)
    }

    pub def post(v: { id = Int64, userId = Int64, title = String, published = Bool, views = Int32 }): PostView =
        PostView.PostView(v#id, v#userId, v#title, v#published, v#views)

    pub def ofPostRow(row: PostsQueries.PostsByUsersRow): PostView =
        post({ id = row#id, userId = row#userId, title = row#title, published = row#published, views = row#views })

    ///
    /// JOIN 後の記事 + 投稿者。
    ///
    pub enum PostWithAuthorView with Eq, Order, ToString {
        case PostWithAuthorView(Int64, String, String, List[String], String, Option[String])
    }

    pub def postWithAuthor(v: { id = Int64, title = String, body = String, tags = List[String], authorName = String, authorEmail = Option[String] }): PostWithAuthorView =
        PostWithAuthorView.PostWithAuthorView(v#id, v#title, v#body, v#tags, v#authorName, v#authorEmail)

    pub def ofPostWithAuthorRow(row: PostsQueries.PostWithAuthorRow): PostWithAuthorView =
        postWithAuthor({ id = row#id, title = row#title, body = row#body, tags = row#tags, authorName = row#authorName, authorEmail = row#authorEmail })

}
