///
/// ライブラリの使い方の見本。ユースケース関数のシグネチャに「読むだけ」「書く」「DB エラーは上へ流す」が出る。
/// 本体には入れず、テストからだけ使う。
///
mod ExampleUsers {

    use SqlValue.SqlValue
    use Decoder.Decoder

    ///
    /// users テーブルの 1 行。
    ///
    /// - `id`: 主キー
    /// - `name`: 表示名
    /// - `email`: 未設定なら None
    ///
    pub type alias User = { id = Int64, name = String, email = Option[String] }

    ///
    /// users の列を User に組む。
    ///
    pub def userDecoder(): Decoder[User] =
        Decoder.pure(id -> name -> email -> { id = id, name = name, email = email })
            |> Decoder.ap(Decoder.int64("id"))
            |> Decoder.ap(Decoder.str("name"))
            |> Decoder.ap(Decoder.opt(Decoder.str("email")))

    ///
    /// id で 1 人取る。無ければ None。読むだけなので SqlWrite は付かない。
    ///
    pub def findUser(id: Int64): Option[User] \ DbRead + RawSql =
        Sql.fetchOneAs(userDecoder(), "SELECT id, name, email FROM users WHERE id = $1", List#{SqlValue.Int64(id)})

    ///
    /// 全員を名前順で取る。
    ///
    pub def listUsers(): List[User] \ DbRead + RawSql =
        Sql.fetchAs(userDecoder(), "SELECT id, name, email FROM users ORDER BY name", Nil)

    ///
    /// 名前を変える。書くのでシグネチャに SqlWrite が出る。影響 0 行なら false。unique 違反は DbErr.uniqueViolation で上がる。
    ///
    pub def renameUser(id: Int64, name: String): Bool \ DbWrite + RawSql =
        Sql.execute("UPDATE users SET name = $1 WHERE id = $2", List#{SqlValue.Str(name), SqlValue.Int64(id)}) > 0

}
