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
    /// 登録が業務として失敗する理由。DB の制約違反のうち、アプリが分岐したい物。
    /// DbErr と同じくエフェクトで上げるので、途中の関数は戻り値を包まず、境界で 1 回ハンドリングする。
    ///
    pub eff RegisterErr {
        /// その email は既に使われている
        def emailTaken(email: String): Void
        /// name が長すぎる（DDL の users_name_length）
        def nameTooLong(): Void
    }

    ///
    /// RegisterErr を 1 層の値にした形。DbFailure と同じく境界（HTTP ハンドラ / テスト）用で、`runRegister` が返す。
    ///
    pub enum RegisterFailure with Eq, Order, ToString {
        case EmailTaken(String)
        case NameTooLong
    }

    ///
    /// RegisterErr を Result に落とす。境界で使う。
    ///
    pub def runRegister(thunk: Unit -> a \ ef): Result[RegisterFailure, a] \ ef - RegisterErr =
        run {
            Ok(thunk())
        } with handler RegisterErr {
            def emailTaken(email, _resume) = Err(RegisterFailure.EmailTaken(email))
            def nameTooLong(_resume) = Err(RegisterFailure.NameTooLong)
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
    /// 投稿者を登録して id を返す。制約違反は生成された `UsersTable.onConstraint` で業務エラーに翻訳する。
    /// enum に無い名前の違反と、制約違反以外の DB エラーはそのまま上へ流れる。
    ///
    /// WhyNot: 制約名の文字列で分岐しないのは、DDL に制約を足したときに翻訳の書き忘れをコンパイルで見つけるため。
    ///
    pub def registerUser(user: NewUser): Int64 \ DbWrite + RegisterErr =
        UsersTable.onConstraint(translateUserConstraint(user#email), () ->
            UsersQueries.insertUser({ name = user#name, email = user#email, role = "member" }) |> expectRow)

    ///
    /// users の制約違反 → 業務エラー。email は EmailTaken に載せる分。
    ///
    def translateUserConstraint(email: String, constraint: UsersTable.Constraint): a \ RegisterErr = match constraint {
        case UsersTable.Constraint.EmailKey => RegisterErr.emailTaken(email)
        case UsersTable.Constraint.NameLength => RegisterErr.nameTooLong()
    }

    ///
    /// RETURNING id の行。無いのは DB かドライバの異常なので DbErr にする。
    ///
    def expectRow(row: Option[{ id = Int64 }]): Int64 \ DbErr = match row {
        case Some(found) => found#id
        case None => DbErr.other("INSERT ... RETURNING returned no row")
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
    /// 記事の編集フォーム。None は「触っていない」。
    ///
    /// - `title`: 題名
    /// - `body`: 本文
    /// - `published`: 公開するか
    ///
    pub type alias PostEdit = { title = Option[String], body = Option[String], published = Option[Bool] }

    ///
    /// 記事を編集する。触った項目だけ UPDATE に出る。何も触っていなければ DB に出さず 0。
    /// 「記事が無い」と「何も触っていない」はどちらも 0 なので、区別したければ先に postWithAuthor で読む。
    ///
    pub def editPost(id: Int64, edit: PostEdit): Int32 \ DbWrite =
        Fragment.noChange()
            |> Fragment.setIfSome(PostsTable.title(), edit#title)
            |> Fragment.setIfSome(PostsTable.body(), edit#body)
            |> Fragment.setIfSome(PostsTable.published(), edit#published)
            |> PostsQueries.updatePost(id)

    ///
    /// 投稿者の email を外す（NULL にする）。退会済みなら 0。
    ///
    pub def clearEmail(id: Int64): Int32 \ DbWrite =
        Fragment.noChange() |> Fragment.setNull(UsersTable.email()) |> UsersQueries.updateUser(id)

    ///
    /// 投稿者を退会させる。記事を消してから soft delete。1 つの Tx で呼ぶこと。
    /// 既に退会済みなら false。
    ///
    pub def removeUser(id: Int64): Bool \ DbWrite =
        discard PostsQueries.deletePostsOfUser(id);
        UsersQueries.softDeleteUser(id) > 0

}
