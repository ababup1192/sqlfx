///
/// デモアプリのユースケース。生成された UsersQueries / PostsQueries を組み合わせる層。
/// シグネチャのエフェクトが「読むだけ」「書く」「DB エラーを上へ流す」を表す。
///
mod Blog {

    use UsersQueries.SearchUsersRow
    use PostsQueries.PostsByUsersRow
    use DbError.DbErrorKind

    ///
    /// 投稿者と、その人の記事。
    ///
    /// - `user`: 投稿者
    /// - `posts`: id 順の記事。無ければ Nil
    ///
    pub type alias UserWithPosts = { user = SearchUsersRow, posts = List[PostsByUsersRow] }

    ///
    /// 登録が業務として失敗する理由。DB のエラーのうち、アプリが分岐したい物だけを値にする。
    ///
    pub enum RegisterError with Eq, Order, ToString {
        /// その email は既に使われている
        case EmailTaken(String)
    }

    ///
    /// 新しい記事。
    ///
    /// - `author`: 投稿者の id
    /// - `title` / `body` / `tags`: 中身
    ///
    pub type alias NewPost = { author = Int64, title = String, body = String, tags = List[String] }

    ///
    /// 登録する投稿者。
    ///
    pub type alias NewUser = { name = String, email = String }

    ///
    /// 検索の条件。
    ///
    /// - `prefix`: 名前の前方一致。空なら全員
    /// - `limit`: 最大件数
    ///
    pub type alias UserSearch = { prefix = String, limit = Int64 }

    ///
    /// 投稿者を登録して id を返す。email の重複は unique 違反として上がるので、ここで業務のエラーに変える。
    /// それ以外の DB エラーはそのまま上へ流す（`DbError.raise`）。
    ///
    pub def registerUser(user: NewUser): Result[RegisterError, Int64] \ DbWrite =
        match DbError.runWithKind(() -> UsersQueries.insertUser({ name = user#name, email = user#email, role = "member" })) {
            case Ok(Some(row)) => Ok(row#id)
            case Ok(None) => DbErr.other("INSERT ... RETURNING returned no row")
            case Err(DbErrorKind.UniqueViolation("users_email_key")) => Err(RegisterError.EmailTaken(user#email))
            case Err(kind) => DbError.raise(kind)
        }

    ///
    /// 名前が prefix で始まる、削除されていない投稿者を名前順で。prefix が空なら全員。
    /// 絞り込みは断片 DSL で組むので、列名の文字列はここに出ない。
    ///
    pub def activeUsersNamed(search: UserSearch): List[SearchUsersRow] \ DbRead =
        UsersQueries.searchUsers(
            search#limit,
            Fragment.when(search#prefix != "", Fragment.like(UsersTable.name(), search#prefix + "%")),
            Fragment.asc(UsersTable.name()))

    ///
    /// 投稿者と記事を 2 クエリで取る（IN 句バッチの preload）。件数に関わらずクエリは 2 つ。
    ///
    /// WhyNot: keyed からの preloader 生成はフェーズ 3 なので、ここでは Preload.attach で束ねる。
    ///
    pub def usersWithPosts(limit: Int64): List[UserWithPosts] \ DbRead =
        let users = UsersQueries.searchUsers(limit, Fragment.always(), Fragment.asc(UsersTable.id()));
        Preload.attach({
            parents = users,
            parentKey = user -> user#id,
            children = PostsQueries.postsByUsers(List.map(user -> user#id, users)),
            childKey = post -> post#userId
        }) |> List.map(pair -> { let (user, posts) = pair; { user = user, posts = posts } })

    ///
    /// 記事を書いて公開する。書いた記事の id を返す。id は INSERT の RETURNING から取るので、同時に他人が書いても混ざらない。
    ///
    pub def publishNewPost(post: NewPost): Option[Int64] \ DbWrite =
        let inserted = PostsQueries.insertPost({ userId = post#author, title = post#title, body = post#body, tags = post#tags }) |> Option.map(row -> row#id);
        Option.forEach(id -> discard PostsQueries.publishPost(id), inserted);
        inserted

    ///
    /// 投稿者を退会させる。記事を消してから soft delete。1 つの Tx で呼ぶこと。
    /// 既に退会済みなら false。
    ///
    pub def removeUser(id: Int64): Bool \ DbWrite =
        discard PostsQueries.deletePostsOfUser(id);
        UsersQueries.softDeleteUser(id) > 0

}
