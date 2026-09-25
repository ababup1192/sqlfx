pub mod Sqlfx.Db {

    use Sqlfx.DbErr
    use Sqlfx.DbError
    use Sqlfx.TransientDbErr

    import java.lang.StackOverflowError
    import java.lang.StackTraceElement
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
    /// attempt は Tx を巻き戻さない。`withLazyTx` の thunk の中で使うと、DB で落ちた SQL の後は Tx が aborted のままで
    /// COMMIT されず `DbErr.rollback` になり、DB に届く前の失敗なら `Err` が普通の戻り値になって COMMIT される。
    /// Tx の外か `withConnection` の中で使い、Tx の中で失敗を値にしたいなら `Pool.withLazyTxResult`、
    /// Tx の一部分だけを巻き戻して続けたいなら `Tx.withSavepoint`。
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
    /// thunk を走らせ、Throwable を値にする。fatal も値にするので、受けた側は `isFatal` を見て、fatal なら
    /// 接続を始末（`Pool.evict`）してから投げ直す。自前の SqlRead / SqlWrite の handler の本体を包むのに使う。
    ///
    pub def catchAll(thunk: Unit -> a \ ef): Result[Throwable, a] \ ef =
        try {
            Ok(thunk())
        } catch {
            case error: Throwable => Err(error)
        }

    ///
    /// `catchAll` の結果を元に戻す。`Err` の Throwable は同じ物を投げ直す（値にしない・包まない）。
    ///
    /// sqlfx が利用側の thunk を包んで handler を張る所は `run { Ok(catchAll(thunk)) } with handler …` と書き、
    /// `run` を抜けてからこれを通す。thunk が外の handler へ op を投げた後で投げた物は、`run` の中で投げ直すと
    /// 外側の catch（`Pool.withLazyTx` の `Db.guard`）を素通りするが、`run` を抜けた後なら届く。
    ///
    /// WhyNot: 投げ直しの IO を署名に出さないのは、投げるのは thunk が既に投げた物で、新しい副作用ではないため。
    /// 出すと `Db.attempt` や `RawSql.runWithAllow` のような純粋な入口の型が全部変わる。
    ///
    pub def rethrowing(outcome: Result[Throwable, a]): a = match outcome {
        case Ok(value)  => value
        case Err(error) => unchecked_cast(throwAgain(error) as _ \ {})
    }

    ///
    /// 投げる。
    ///
    def throwAgain(error: Throwable): a \ IO = throw error

    ///
    /// 飲み込んではいけない物か。`VirtualMachineError`（OutOfMemoryError / InternalError）は true。
    /// 例外自身と、cause の連鎖を深さ 8 まで見る。
    ///
    /// WhyNot: 一番外の例外だけを見ないのは、graphql-java や Future が中の OutOfMemoryError を
    /// `CompletionException` に包んで投げ返し、外側だけ見ると fatal でない物として値にしてしまうため。
    ///
    pub def isFatal(error: Throwable): Bool \ IO =
        isFatalWithin(error, 0)

    ///
    /// cause を辿る深さの上限。自分を cause に持つ物や長い連鎖で止まらなくならないように。
    ///
    def maxCauseDepth(): Int32 = 8

    def isFatalWithin(error: Throwable, depth: Int32): Bool \ IO =
        if (isFatalItself(error)) true
        else {
            let cause = error.getCause();
            if (Object.isNull(cause) or depth >= maxCauseDepth()) false
            else isFatalWithin(cause, depth + 1)
        }

    ///
    /// その例外自体が fatal か（cause は見ない）。
    ///
    /// WhyNot: StackOverflowError を fatal にしないのは、VirtualMachineError の子ではあるが 1 つの Tx の深い再帰で
    /// 起きる物で、その Tx を巻き戻せば JVM は続けられるため。
    ///
    /// WhyNot: `instanceof` でなく throw して catch で分けるのは、Flix に型の判定式が無く、catch の並びなら
    /// 子クラスを先に書けるため。
    ///
    def isFatalItself(error: Throwable): Bool \ IO =
        try {
            throw error
        } catch {
            case _: StackOverflowError  => false
            case _: VirtualMachineError => true
            case _: Throwable           => false
        }

    ///
    /// pgjdbc の中から出た例外か。例外の class 名か、stack trace の先頭の frame の class 名が `org.postgresql.` で始まる物。
    /// fatal でなくても、pgjdbc の中の例外は protocol の途中で出うるので、その接続は捨てる（ROLLBACK を送らない）。
    ///
    /// WhyNot: fatal でない例外を全部「接続を捨てる」側に倒さないのは、sqlfx 側の変換（JdbcConvert）の失敗は
    /// 接続の protocol に触っておらず、ROLLBACK して返せば足りるため。
    ///
    pub def fromDriver(error: Throwable): Bool \ IO =
        let className: String = error.getClass().getName();
        let frames = error.getStackTrace();
        let topFrame: String = if (Array.length(frames) == 0) "" else { let frame: StackTraceElement = Array.get(0, frames); frame.getClassName() };
        isDriverClass(className) or isDriverClass(topFrame)

    ///
    /// pgjdbc の class 名か。
    ///
    def isDriverClass(name: String): Bool =
        String.startsWith(prefix = "org.postgresql.", name)

    ///
    /// 例外の 1 行。message があればそれ、null ならクラス名（VerifyError は message が null の事がある）。
    ///
    def describeThrowable(error: Throwable): String \ IO =
        let message: String = error.getMessage();
        if (Object.isNull(message)) error.getClass().getName() else message

}
