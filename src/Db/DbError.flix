///
/// 一時障害。Tx 境界ごと再実行すれば回復しうる。インフラ層の withRetry で捌く。
/// op は 1 つで、種類は `DbErrorKind` の値で渡す（`isTransient` が true の case だけを渡す約束）。
/// 投げるのは `TransientDbErr.deadlock()` のような関数（`mod TransientDbErr`）。
///
/// WhyNot: 種類ごとに op を分けないのは、case を 1 つ足すたびに「素通しするだけ」の handler まで含めて
/// 利用側の全 handler がコンパイルエラーになるため。壊れる範囲を「網羅 match を書いた所」だけに縮める。
///
pub eff TransientDbErr {
    def raise(kind: DbError.DbErrorKind): Void
}

///
/// 再実行しても直らない DB エラー。制約違反はアプリが分岐したければハンドラで拾い、それ以外は main でログを出して終了する。
/// op は 1 つで、種類は `DbErrorKind` の値で渡す（`isTransient` が false の case だけを渡す約束）。
/// 投げるのは `DbErr.uniqueViolation(constraint)` のような関数（`mod DbErr`）。
///
pub eff DbErr {
    def raise(kind: DbError.DbErrorKind): Void
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

mod TransientDbErr {

    use DbError.DbErrorKind

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
        TransientDbErr.raise(DbErrorKind.Transient(transient))

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

mod DbErr {

    use DbError.DbErrorKind

    ///
    /// unique 制約違反（制約名）。
    ///
    pub def uniqueViolation(constraint: String): a \ DbErr = DbErr.raise(DbErrorKind.UniqueViolation(constraint))

    ///
    /// 外部キー制約違反（制約名）。
    ///
    pub def foreignKeyViolation(constraint: String): a \ DbErr = DbErr.raise(DbErrorKind.ForeignKeyViolation(constraint))

    ///
    /// CHECK 制約違反（制約名）。
    ///
    pub def checkViolation(constraint: String): a \ DbErr = DbErr.raise(DbErrorKind.CheckViolation(constraint))

    ///
    /// NOT NULL 違反（列名）。生成された関数の引数の型が守るので、生 SQL か UPDATE で NULL を書いたときに出る。
    ///
    pub def notNullViolation(column: String): a \ DbErr = DbErr.raise(DbErrorKind.NotNullViolation(column))

    ///
    /// テーブルや列が無い = デプロイミス。
    ///
    pub def schemaMismatch(detail: String): a \ DbErr = DbErr.raise(DbErrorKind.SchemaMismatch(detail))

    ///
    /// 結果セットの列が期待した型で読めない。
    ///
    pub def decodeError(column: String, detail: String): a \ DbErr = DbErr.raise(DbErrorKind.DecodeError(column, detail))

    ///
    /// withRetry が枯渇した。last は最後の失敗、attempts は呼んだ回数。
    ///
    pub def retryExhausted(last: DbError.TransientKind, attempts: Int32): a \ DbErr =
        DbErr.raise(DbErrorKind.RetryExhausted(last, attempts))

    ///
    /// 業務の都合で Tx を巻き戻したい。DB の失敗ではない。値で受けたいなら `Pool.withLazyTxResult`。
    ///
    pub def rollback(): a \ DbErr = DbErr.raise(DbErrorKind.Rollback)

    ///
    /// 上のどれにも当てはまらない DB エラー（sqlstate とメッセージ）。
    ///
    pub def other(detail: String): a \ DbErr = DbErr.raise(DbErrorKind.Other(detail))

    ///
    /// DbErr だけを Result に落とす。Transient は上へ流したまま、DbErr だけ値にしたいときに使う。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[String, a] \ ef - DbErr =
        run {
            Ok(thunk())
        } with handler DbErr {
            def raise(kind, _resume) = Err(DbError.describe(kind))
        }

}

mod Db {

    import java.lang.StackOverflowError
    import java.lang.Throwable
    import java.lang.VirtualMachineError

    ///
    /// DB の失敗を値で受ける。`Result` が欲しい所（バッチで 1 行ごとの結果を集める、失敗を数える）用の唯一の入口。
    ///
    /// ```
    /// rows |> List.map(row -> (row, Db.attempt(() -> UsersQueries.insertUser(row))))
    /// ```
    ///
    /// WhyNot: クエリごとに `tryXxx` を生成しないのは、Tx の中で使うと COMMIT される入口を生成物の数だけ増やすため。
    /// 値で受けたい所は 1 本のこれを通す。
    ///
    /// attempt は Tx を巻き戻さない。`withLazyTx` の thunk の中で使うと `Err` が普通の戻り値になって COMMIT される。
    /// Tx の外か `withConnection` の中で使い、Tx の中で失敗を値にしたいなら `Pool.withLazyTxResult`。
    ///
    pub def attempt(thunk: Unit -> a \ ef): Result[DbError.Failure, a] \ ef - {TransientDbErr, DbErr} =
        DbError.runWithFailure(thunk)

    ///
    /// thunk を走らせ、JVM の例外（Java interop、VerifyError、写しのコードの RuntimeException）を
    /// `DbErr` の `Other` に変える。JVM 自体が壊れている物（`OutOfMemoryError` のような `VirtualMachineError`。
    /// `StackOverflowError` は除く）はそのまま再送出する。文言は message、無ければ class 名。
    ///
    /// `Pool.withLazyTx` はこれを thunk の最内側に置いているが、その catch は利用側が thunk の中で張った
    /// handler の内側には届かない。自分の handler を張るなら、一番内側の handler の直下にこれを置く。
    ///
    /// ```
    /// Pool.withLazyTx(pool, () -> BizErr.runWithResult(() -> Db.guard(() -> work())))
    /// ```
    ///
    /// WhyNot: catch の腕で op（`DbErr.other`）を直に呼ばないのは、JVM の VerifyError になるため。
    /// 腕では値だけ返し、catch を抜けてから raise する。
    ///
    pub def guard(thunk: Unit -> a \ ef): a \ ef + IO + DbErr =
        match catchAll(thunk) {
            case Ok(value)  => value
            case Err(error) => if (isFatal(error)) throw error else DbErr.other(describeThrowable(error))
        }

    ///
    /// thunk を走らせ、Throwable を値にする。
    ///
    def catchAll(thunk: Unit -> a \ ef): Result[Throwable, a] \ ef =
        try {
            Ok(thunk())
        } catch {
            case error: Throwable => Err(error)
        }

    ///
    /// 飲み込んではいけない物か。`VirtualMachineError`（OutOfMemoryError / InternalError）は true。
    ///
    /// WhyNot: StackOverflowError を fatal にしないのは、VirtualMachineError の子ではあるが 1 つの Tx の深い再帰で
    /// 起きる物で、その Tx を巻き戻せば JVM は続けられるため。
    ///
    /// WhyNot: `instanceof` でなく throw して catch で分けるのは、Flix に型の判定式が無く、catch の並びなら
    /// 子クラスを先に書けるため。
    ///
    pub def isFatal(error: Throwable): Bool \ IO =
        try {
            throw error
        } catch {
            case _: StackOverflowError  => false
            case _: VirtualMachineError => true
            case _: Throwable           => false
        }

    ///
    /// 例外の 1 行。message があればそれ、null ならクラス名（VerifyError は message が null の事がある）。
    ///
    def describeThrowable(error: Throwable): String \ IO =
        let message: String = error.getMessage();
        if (Object.isNull(message)) error.getClass().getName() else message

}
