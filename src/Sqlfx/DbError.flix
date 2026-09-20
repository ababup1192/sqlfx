pub mod Sqlfx.DbError {

    use Sqlfx.DbErr
    use Sqlfx.TransientDbErr

    ///
    /// 2 つのエフェクトの全 op を値にした形。op と 1:1 で、`raise` で op に戻せる。
    /// JDBC ハンドラは SQLException をまずこれに落とし（翻訳表は DB 無しでテストする）、
    /// Tx や接続の後始末はこれを受け取ってから op に戻す。
    ///
    pub enum TransientKind with Eq, Order, ToString {
        /// デッドロック（PG は 40001 / 40P01）
        case Deadlock
        /// statement_timeout 等。ms は分かるときだけ、分からなければ 0
        case Timeout(Int32)
        /// 接続が切れた・届かない
        case ConnectionLost(String)
    }

    ///
    /// 2 つのエフェクトの op を値にした形。`raise` で op に戻せる。
    /// JDBC ハンドラは SQLException をまずこれに落とし（翻訳表は DB 無しでテストする）、
    /// Tx や接続の後始末はこれを受け取ってから op に戻す。
    ///
    /// WhyNot: 一時障害を別の enum に割らないのは、`SqlRead` / `SqlWrite` の op が返す `Result[DbErrorKind, _]` と
    /// `DbTest.runFailingWrite` の署名が 1 つの型を前提にしているため。`Transient` の case で内側に持つ。
    ///
    pub enum DbErrorKind with Eq, Order, ToString {
        /// 再実行で直りうる失敗
        case Transient(TransientKind)
        case UniqueViolation(String)
        case ForeignKeyViolation(String)
        case CheckViolation(String)
        case NotNullViolation(String)
        case SchemaMismatch(String)
        case DecodeError(String, String)
        /// withRetry が枯渇した。最後の失敗と、呼んだ回数
        case RetryExhausted(TransientKind, Int32)
        /// 業務の都合で Tx を巻き戻したい。値で受けたいなら `Pool.withLazyTxResult`
        case Rollback
        case Other(String)
    }

    ///
    /// 再実行で直りうる物か。
    ///
    pub def isTransient(kind: DbErrorKind): Bool = match kind {
        case DbErrorKind.Transient(_) => true
        case _ => false
    }

    ///
    /// 一時障害なら中身の `TransientKind`。
    ///
    pub def transientOf(kind: DbErrorKind): Option[TransientKind] = match kind {
        case DbErrorKind.Transient(transient) => Some(transient)
        case _ => None
    }

    ///
    /// 値を対応する op として投げる。戻らない。
    ///
    pub def raise(kind: DbErrorKind): a \ {TransientDbErr, DbErr} =
        if (isTransient(kind)) TransientDbErr.raise(kind) else DbErr.raise(kind)

    ///
    /// 2 つのエフェクトをまとめて値に落とす唯一のハンドラ。他の「Result にする」関数はこれから作る。
    ///
    pub def runWithKind(thunk: Unit -> a \ ef): Result[DbErrorKind, a] \ ef - {TransientDbErr, DbErr} =
        run {
            Ok(thunk())
        } with handler TransientDbErr {
            def raise(kind, _resume) = Err(kind)
        } with handler DbErr {
            def raise(kind, _resume) = Err(kind)
        }

    ///
    /// 制約違反の制約名。UNIQUE / FK / CHECK だけ。notNullViolation は列名なので None。
    ///
    pub def constraintName(kind: DbErrorKind): Option[String] = match kind {
        case DbErrorKind.UniqueViolation(constraint) => Some(constraint)
        case DbErrorKind.ForeignKeyViolation(constraint) => Some(constraint)
        case DbErrorKind.CheckViolation(constraint) => Some(constraint)
        case DbErrorKind.NotNullViolation(_) => None
        case DbErrorKind.SchemaMismatch(_) => None
        case DbErrorKind.DecodeError(_, _) => None
        case DbErrorKind.Transient(_) => None
        case DbErrorKind.RetryExhausted(_, _) => None
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
    /// 業務コードはこれを返さず、エフェクトのまま上へ流す。人が読む 1 行は `describeFailure`。
    ///
    pub enum Failure with Eq, Order, ToString {
        /// 再実行で直りうる失敗
        case Transient(TransientKind)
        /// 再実行しても直らない失敗
        case Permanent(DbErrorKind)
    }

    ///
    /// 旧名（0.3.x）。型の位置でだけ使える（`DbFailure.Permanent(...)` とは書けない）。
    ///
    pub type alias DbFailure = Failure

    ///
    /// 2 分類をまとめて 1 層の Result に落とす。Ok なら失敗無し。
    ///
    pub def runWithFailure(thunk: Unit -> a \ ef): Result[Failure, a] \ ef - {TransientDbErr, DbErr} =
        runWithKind(thunk) |> Result.mapErr(toFailure)

    ///
    /// 人が読む 1 行にする。
    ///
    pub def describe(kind: DbErrorKind): String = match kind {
        case DbErrorKind.Transient(transient) => describeTransient(transient)
        case DbErrorKind.UniqueViolation(constraint) => "uniqueViolation ${constraint}"
        case DbErrorKind.ForeignKeyViolation(constraint) => "foreignKeyViolation ${constraint}"
        case DbErrorKind.CheckViolation(constraint) => "checkViolation ${constraint}"
        case DbErrorKind.NotNullViolation(column) => "notNullViolation ${column}"
        case DbErrorKind.SchemaMismatch(detail) => "schemaMismatch ${detail}"
        case DbErrorKind.DecodeError(column, detail) => "${column}: ${detail}"
        case DbErrorKind.RetryExhausted(last, attempts) => "retryExhausted ${describeTransient(last)} after ${attempts} attempts"
        case DbErrorKind.Rollback => "rollback"
        case DbErrorKind.Other(detail) => "other ${detail}"
    }

    ///
    /// 一時障害を人が読む 1 行にする。
    ///
    pub def describeTransient(transient: TransientKind): String = match transient {
        case TransientKind.Deadlock => "deadlock"
        case TransientKind.Timeout(ms) => "timeout ${ms}"
        case TransientKind.ConnectionLost(msg) => "connectionLost ${msg}"
    }

    ///
    /// 失敗を人が読む 1 行にする。
    ///
    pub def describeFailure(failure: Failure): String = match failure {
        case Failure.Transient(transient) => describeTransient(transient)
        case Failure.Permanent(kind)      => describe(kind)
    }

    def toFailure(kind: DbErrorKind): Failure = match transientOf(kind) {
        case Some(transient) => Failure.Transient(transient)
        case None            => Failure.Permanent(kind)
    }

}
