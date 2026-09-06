use SqlValue.SqlValue

///
/// DB 無しテストで使う users / posts の行。生成版と生 SQL 版のテストが共有する（デコーダは余分な列を無視する）。
///
mod BlogRows {

    use Row.Row

    ///
    /// users の 1 人。role は member 固定。
    ///
    pub type alias UserSeed = { id = Int64, name = String, email = Option[String] }

    ///
    /// posts の 1 件。published は true、views は 0 固定。
    ///
    pub type alias PostSeed = { id = Int64, userId = Int64, title = String }

    pub def users(seeds: List[UserSeed]): List[Row] =
        Row.makeRows(List#{"id", "name", "email", "role"},
            List.map(user -> List#{SqlValue.Int64(user#id), SqlValue.Str(user#name), Option.map(SqlValue.Str, user#email) |> Option.getWithDefault(SqlValue.Null), SqlValue.Str("member")}, seeds))

    pub def posts(seeds: List[PostSeed]): List[Row] =
        Row.makeRows(List#{"id", "user_id", "title", "published", "views"},
            List.map(post -> List#{SqlValue.Int64(post#id), SqlValue.Int64(post#userId), SqlValue.Str(post#title), SqlValue.Bool(true), SqlValue.Int32(0)}, seeds))

    ///
    /// SQL の FROM を見て users か posts の行を返す（DbTest.runWithTable / runRecordingWith 用）。
    ///
    pub def tableFor(seeds: { users = List[UserSeed], posts = List[PostSeed] }): String -> Option[List[Row]] =
        sql -> if (String.contains(substr = "FROM posts", sql)) Some(posts(seeds#posts)) else Some(users(seeds#users))

    ///
    /// 3 人と 3 記事。alice に 2 件、carol に 1 件、bob は無し。
    ///
    pub def sample(): { users = List[UserSeed], posts = List[PostSeed] } = {
        users = List#{
            { id = 1i64, name = "alice", email = Some("alice@example.com") },
            { id = 2i64, name = "bob", email = None },
            { id = 3i64, name = "carol", email = None }
        },
        posts = List#{
            { id = 10i64, userId = 1i64, title = "a1" },
            { id = 11i64, userId = 1i64, title = "a2" },
            { id = 12i64, userId = 3i64, title = "c1" }
        }
    }

}
