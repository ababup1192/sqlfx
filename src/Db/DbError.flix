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
    /// CHECK 制約違反（制約名）
    def checkViolation(constraint: String): Void
    /// NOT NULL 違反（列名）。生成された関数の引数の型が守るので、生 SQL か UPDATE で NULL を書いたときに出る
    def notNullViolation(column: String): Void
    /// テーブルや列が無い = デプロイミス
    def schemaMismatch(detail: String): Void
    /// 結果セットの列が期待した型で読めない
    def decodeError(column: String, detail: String): Void
    /// withRetry が枯渇した。last は最後の失敗の説明
    def retryExhausted(last: String): Void
    /// 業務の都合で Tx を巻き戻したい。DB の失敗ではない
    def rollback(): Void
    /// 上のどれにも当てはまらない DB エラー（sqlstate とメッセージ）
    def other(detail: String): Void
}

///
/// エフェクト集合をまとめて書くための alias。ハンドラは個別に被せる。
///
pub type alias Db = {SqlRead, SqlWrite, TransientDbErr, DbErr}

mod DbError {

    ///
    /// 2 つのエフェクトの全 op を値にした形。op と 1:1 で、`raise` で op に戻せる。
    /// JDBC ハンドラは SQLException をまずこれに落とし（翻訳表は DB 無しでテストする）、
    /// Tx や接続の後始末はこれを受け取ってから op に戻す。
    ///
    pub enum DbErrorKind with Eq, Order, ToString {
        case Deadlock
        case Timeout(Int32)
        case ConnectionLost(String)
        case UniqueViolation(String)
        case ForeignKeyViolation(String)
        case CheckViolation(String)
        case NotNullViolation(String)
        case SchemaMismatch(String)
        case DecodeError(String, String)
        case RetryExhausted(String)
        /// 業務の都合で Tx を巻き戻したい。値で受けたいなら `Pool.withLazyTxResult`
        case Rollback
        case Other(String)
    }

    ///
    /// 再実行で直りうる物か。
    ///
    pub def isTransient(kind: DbErrorKind): Bool = match kind {
        case DbErrorKind.Deadlock => true
        case DbErrorKind.Timeout(_) => true
        case DbErrorKind.ConnectionLost(_) => true
        case _ => false
    }

    ///
    /// 値を対応する op として投げる。戻らない。
    ///
    pub def raise(kind: DbErrorKind): a \ {TransientDbErr, DbErr} = match kind {
        case DbErrorKind.Deadlock => TransientDbErr.deadlock()
        case DbErrorKind.Timeout(ms) => TransientDbErr.timeout(ms)
        case DbErrorKind.ConnectionLost(msg) => TransientDbErr.connectionLost(msg)
        case DbErrorKind.UniqueViolation(constraint) => DbErr.uniqueViolation(constraint)
        case DbErrorKind.ForeignKeyViolation(constraint) => DbErr.foreignKeyViolation(constraint)
        case DbErrorKind.CheckViolation(constraint) => DbErr.checkViolation(constraint)
        case DbErrorKind.NotNullViolation(column) => DbErr.notNullViolation(column)
        case DbErrorKind.SchemaMismatch(detail) => DbErr.schemaMismatch(detail)
        case DbErrorKind.DecodeError(column, detail) => DbErr.decodeError(column, detail)
        case DbErrorKind.RetryExhausted(last) => DbErr.retryExhausted(last)
        case DbErrorKind.Rollback => DbErr.rollback()
        case DbErrorKind.Other(detail) => DbErr.other(detail)
    }

    ///
    /// 2 つのエフェクトをまとめて値に落とす唯一のハンドラ。他の「Result にする」関数はこれから作る。
    ///
    pub def runWithKind(thunk: Unit -> a \ ef): Result[DbErrorKind, a] \ ef - {TransientDbErr, DbErr} =
        run {
            Ok(thunk())
        } with handler TransientDbErr {
            def deadlock(_resume) = Err(DbErrorKind.Deadlock)
            def timeout(ms, _resume) = Err(DbErrorKind.Timeout(ms))
            def connectionLost(msg, _resume) = Err(DbErrorKind.ConnectionLost(msg))
        } with handler DbErr {
            def uniqueViolation(constraint, _resume) = Err(DbErrorKind.UniqueViolation(constraint))
            def foreignKeyViolation(constraint, _resume) = Err(DbErrorKind.ForeignKeyViolation(constraint))
            def checkViolation(constraint, _resume) = Err(DbErrorKind.CheckViolation(constraint))
            def notNullViolation(column, _resume) = Err(DbErrorKind.NotNullViolation(column))
            def schemaMismatch(detail, _resume) = Err(DbErrorKind.SchemaMismatch(detail))
            def decodeError(column, detail, _resume) = Err(DbErrorKind.DecodeError(column, detail))
            def retryExhausted(last, _resume) = Err(DbErrorKind.RetryExhausted(last))
            def rollback(_resume) = Err(DbErrorKind.Rollback)
            def other(detail, _resume) = Err(DbErrorKind.Other(detail))
        }

    ///
    /// 制約違反の制約名。UNIQUE / FK / CHECK だけ。notNullViolation は列名なので None。
    ///
    pub def constraintName(kind: DbErrorKind): Option[String] = match kind {
        case DbErrorKind.UniqueViolation(constraint) => Some(constraint)
        case DbErrorKind.ForeignKeyViolation(constraint) => Some(constraint)
        case DbErrorKind.CheckViolation(constraint) => Some(constraint)
        case DbErrorKind.NotNullViolation(_) => None
        case DbErrorKind.Deadlock => None
        case DbErrorKind.Timeout(_) => None
        case DbErrorKind.ConnectionLost(_) => None
        case DbErrorKind.SchemaMismatch(_) => None
        case DbErrorKind.DecodeError(_, _) => None
        case DbErrorKind.RetryExhausted(_) => None
        case DbErrorKind.Rollback => None
        case DbErrorKind.Other(_) => None
    }

    ///
    /// 制約違反を翻訳しながら thunk を走らせる。生成された `XxxTable.onConstraint` の土台。
    /// translate は thunk と同じ型の値を返すか、業務エラーのエフェクトを投げる。
    /// `constraintOf` が None を返す名前（DDL に無い制約）と、制約違反以外の DbErr は raise でそのまま上へ。
    ///
    /// WhyNot: `case _ => None` を書かないのは、DbErrorKind に制約違反の case を足したとき、ここを書き忘れると翻訳が黙って抜けるから。
    ///
    pub def onConstraintWith(constraintOf: String -> Option[c], translate: c -> a \ ef1, thunk: Unit -> a \ ef2): a \ ef1 + ef2 + {TransientDbErr, DbErr} =
        match runWithKind(thunk) {
            case Ok(value) => value
            case Err(kind) => match constraintName(kind) |> Option.flatMap(constraintOf) {
                case Some(constraint) => translate(constraint)
                case None => raise(kind)
            }
        }

    ///
    /// 2 分類を 1 層の Result に落とした失敗。境界（main / HTTP ハンドラ / テスト）で使う。
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
        runWithKind(thunk) |> Result.mapErr(toFailure)

    ///
    /// 人が読む 1 行にする。
    ///
    pub def describe(kind: DbErrorKind): String = match kind {
        case DbErrorKind.Deadlock => "deadlock"
        case DbErrorKind.Timeout(ms) => "timeout ${ms}"
        case DbErrorKind.ConnectionLost(msg) => "connectionLost ${msg}"
        case DbErrorKind.UniqueViolation(constraint) => "uniqueViolation ${constraint}"
        case DbErrorKind.ForeignKeyViolation(constraint) => "foreignKeyViolation ${constraint}"
        case DbErrorKind.CheckViolation(constraint) => "checkViolation ${constraint}"
        case DbErrorKind.NotNullViolation(column) => "notNullViolation ${column}"
        case DbErrorKind.SchemaMismatch(detail) => "schemaMismatch ${detail}"
        case DbErrorKind.DecodeError(column, detail) => "${column}: ${detail}"
        case DbErrorKind.RetryExhausted(last) => "retryExhausted ${last}"
        case DbErrorKind.Rollback => "rollback"
        case DbErrorKind.Other(detail) => "other ${detail}"
    }

    def toFailure(kind: DbErrorKind): DbFailure =
        if (isTransient(kind)) DbFailure.Transient(describe(kind)) else DbFailure.Permanent(describe(kind))

}

mod TransientDbErr {

    ///
    /// TransientDbErr だけを Result に落とす。DbErr は上へ流したまま。withRetry が使う。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[String, a] \ ef - TransientDbErr =
        run {
            Ok(thunk())
        } with handler TransientDbErr {
            def deadlock(_resume) = Err(DbError.describe(DbError.DbErrorKind.Deadlock))
            def timeout(ms, _resume) = Err(DbError.describe(DbError.DbErrorKind.Timeout(ms)))
            def connectionLost(msg, _resume) = Err(DbError.describe(DbError.DbErrorKind.ConnectionLost(msg)))
        }

}

mod DbErr {

    ///
    /// DbErr だけを Result に落とす。Transient は上へ流したまま、DbErr だけ値にしたいときに使う。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[String, a] \ ef - DbErr =
        run {
            Ok(thunk())
        } with handler DbErr {
            def uniqueViolation(constraint, _resume) = Err(DbError.describe(DbError.DbErrorKind.UniqueViolation(constraint)))
            def foreignKeyViolation(constraint, _resume) = Err(DbError.describe(DbError.DbErrorKind.ForeignKeyViolation(constraint)))
            def checkViolation(constraint, _resume) = Err(DbError.describe(DbError.DbErrorKind.CheckViolation(constraint)))
            def notNullViolation(column, _resume) = Err(DbError.describe(DbError.DbErrorKind.NotNullViolation(column)))
            def schemaMismatch(detail, _resume) = Err(DbError.describe(DbError.DbErrorKind.SchemaMismatch(detail)))
            def decodeError(column, detail, _resume) = Err(DbError.describe(DbError.DbErrorKind.DecodeError(column, detail)))
            def retryExhausted(last, _resume) = Err(DbError.describe(DbError.DbErrorKind.RetryExhausted(last)))
            def rollback(_resume) = Err(DbError.describe(DbError.DbErrorKind.Rollback))
            def other(detail, _resume) = Err(DbError.describe(DbError.DbErrorKind.Other(detail)))
        }

}
