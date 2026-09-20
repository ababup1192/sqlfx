pub mod Sqlfx.TransientDbErr {

    use Sqlfx.DbError

    use Sqlfx.DbError.DbErrorKind

    ///
    /// デッドロック（PG は 40001 / 40P01）。
    ///
    pub def deadlock(): a \ TransientDbErr = raiseTransient(DbError.TransientKind.Deadlock)

    ///
    /// statement_timeout 等。ms は分かるときだけ、分からなければ 0。
    ///
    pub def timeout(ms: Int32): a \ TransientDbErr = raiseTransient(DbError.TransientKind.Timeout(ms))

    ///
    /// 接続が切れた・届かない。
    ///
    pub def connectionLost(msg: String): a \ TransientDbErr = raiseTransient(DbError.TransientKind.ConnectionLost(msg))

    ///
    /// 一時障害の種類をそのまま投げる。
    ///
    pub def raiseTransient(transient: DbError.TransientKind): a \ TransientDbErr =
        Sqlfx.TransientDbErr.raise(DbErrorKind.Transient(transient))

    ///
    /// TransientDbErr だけを Result に落とす。DbErr は上へ流したまま。withRetry が使う。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[DbError.TransientKind, a] \ ef - TransientDbErr =
        run {
            Ok(thunk())
        } with handler TransientDbErr {
            def raise(kind, _resume) = Err(asTransient(kind))
        }

    ///
    /// TransientDbErr が運んできた kind の中身。
    ///
    /// WhyNot: 約束に反する kind（Transient でない物）を bug! で落とさないのは、ライブラリの使い方の間違いで
    /// 本番を止めない方が良く、describe を持った ConnectionLost として扱えば情報も落ちないため。
    ///
    def asTransient(kind: DbErrorKind): DbError.TransientKind = match DbError.transientOf(kind) {
        case Some(transient) => transient
        case None            => DbError.TransientKind.ConnectionLost(DbError.describe(kind))
    }

}
