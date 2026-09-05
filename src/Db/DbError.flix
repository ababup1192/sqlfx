///
/// 一時障害。Tx 境界ごと再実行すれば回復しうる。インフラ層の withRetry で捌く。
///
pub eff TransientDbErr {
    def deadlock(): Void
    /// statement_timeout 等。ms は分かるときだけ、分からなければ 0
    def timeout(ms: Int32): Void
    def connectionLost(msg: String): Void
}

///
/// 再実行しても直らない DB エラー。制約違反はアプリが分岐したければハンドラで拾い、それ以外は main でログを出して終了する。
///
pub eff DbErr {
    /// unique 制約違反（制約名）
    def uniqueViolation(constraint: String): Void
    /// 外部キー制約違反（制約名）
    def foreignKeyViolation(constraint: String): Void
    /// テーブルや列が無い = デプロイミス
    def schemaMismatch(detail: String): Void
    /// 結果セットの列が期待した型で読めない
    def decodeError(column: String, detail: String): Void
    /// withRetry が枯渇した。last は最後の失敗の説明
    def retryExhausted(last: String): Void
    /// 上のどれにも当てはまらない DB エラー
    def corrupt(detail: String): Void
}

///
/// エフェクト集合をまとめて書くための alias。ハンドラは個別に被せる。
///
pub type alias Db = {SqlRead, SqlWrite, TransientDbErr, DbErr}

mod DbError {

    ///
    /// 2 分類をまとめて値にした失敗。境界（main / HTTP ハンドラ / テスト）で Result にしたいときだけ使う。
    /// 業務コードはこれを返さず、エフェクトのまま上へ流す。
    ///
    pub enum DbFailure with Eq, Order, ToString {
        /// TransientDbErr の説明
        case Transient(String)
        /// DbErr の説明
        case Permanent(String)
    }

    ///
    /// 2 分類をまとめて 1 層の Result に落とす。Ok なら失敗無し。
    ///
    pub def runWithFailure(thunk: Unit -> a \ ef): Result[DbFailure, a] \ ef - {TransientDbErr, DbErr} =
        run {
            Ok(thunk())
        } with handler TransientDbErr {
            def deadlock(_resume) = Err(DbFailure.Transient("deadlock"))
            def timeout(ms, _resume) = Err(DbFailure.Transient("timeout ${ms}"))
            def connectionLost(msg, _resume) = Err(DbFailure.Transient("connectionLost ${msg}"))
        } with handler DbErr {
            def uniqueViolation(constraint, _resume) = Err(DbFailure.Permanent("uniqueViolation ${constraint}"))
            def foreignKeyViolation(constraint, _resume) = Err(DbFailure.Permanent("foreignKeyViolation ${constraint}"))
            def schemaMismatch(detail, _resume) = Err(DbFailure.Permanent("schemaMismatch ${detail}"))
            def decodeError(column, detail, _resume) = Err(DbFailure.Permanent("${column}: ${detail}"))
            def retryExhausted(last, _resume) = Err(DbFailure.Permanent("retryExhausted ${last}"))
            def corrupt(detail, _resume) = Err(DbFailure.Permanent("corrupt ${detail}"))
        }

    ///
    /// DB エラーをどの op に翻訳するか。JDBC ハンドラは SQLException をまずこれに落とし、翻訳表は DB 無しでテストする。
    ///
    pub enum DbErrorKind with Eq, Order, ToString {
        /// unique 制約違反（制約名）
        case Conflict(String)
        /// 外部キー制約違反（制約名）
        case InvalidRef(String)
        case Deadlock
        /// ms。分からなければ 0
        case Timeout(Int32)
        case ConnectionLost(String)
        case SchemaMismatch(String)
        case Corrupt(String)
    }

    ///
    /// DbErrorKind を対応する op として投げる。戻らない。
    ///
    pub def raise(kind: DbErrorKind): a \ {TransientDbErr, DbErr} = match kind {
        case DbErrorKind.Conflict(constraint) => DbErr.uniqueViolation(constraint)
        case DbErrorKind.InvalidRef(constraint) => DbErr.foreignKeyViolation(constraint)
        case DbErrorKind.Deadlock => TransientDbErr.deadlock()
        case DbErrorKind.Timeout(ms) => TransientDbErr.timeout(ms)
        case DbErrorKind.ConnectionLost(msg) => TransientDbErr.connectionLost(msg)
        case DbErrorKind.SchemaMismatch(detail) => DbErr.schemaMismatch(detail)
        case DbErrorKind.Corrupt(detail) => DbErr.corrupt(detail)
    }

}

mod TransientDbErr {

    ///
    /// TransientDbErr を Result に落とす。withRetry が使う。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[String, a] \ ef - TransientDbErr =
        run {
            Ok(thunk())
        } with handler TransientDbErr {
            def deadlock(_resume) = Err("deadlock")
            def timeout(ms, _resume) = Err("timeout ${ms}")
            def connectionLost(msg, _resume) = Err("connectionLost ${msg}")
        }

}

mod DbErr {

    ///
    /// DbErr を Result に落とす。Transient は上へ流したまま、DbErr だけ値にしたいときに使う。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[String, a] \ ef - DbErr =
        run {
            Ok(thunk())
        } with handler DbErr {
            def uniqueViolation(constraint, _resume) = Err("uniqueViolation ${constraint}")
            def foreignKeyViolation(constraint, _resume) = Err("foreignKeyViolation ${constraint}")
            def schemaMismatch(detail, _resume) = Err("schemaMismatch ${detail}")
            def decodeError(column, detail, _resume) = Err("${column}: ${detail}")
            def retryExhausted(last, _resume) = Err("retryExhausted ${last}")
            def corrupt(detail, _resume) = Err("corrupt ${detail}")
        }

}
