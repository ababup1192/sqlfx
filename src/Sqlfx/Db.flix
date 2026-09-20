pub mod Sqlfx.Db {

    use Sqlfx.DbErr
    use Sqlfx.DbError
    use Sqlfx.TransientDbErr

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
