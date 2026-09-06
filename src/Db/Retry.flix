mod Retry {

    ///
    /// TransientDbErr で失敗したら thunk を最初から呼び直す。attempts 回すべて失敗したら DbErr.retryExhausted。attempts が 1 未満なら 1 回。
    /// thunk は Tx 単位（`withTx` ごと）で渡す。PG はデッドロック後に Tx 全体が aborted になるので、文単位の再実行は意味を持たない。
    ///
    /// WhyNot: 待ち時間（backoff）を入れないのは、v0 では待つ手段（Thread.sleep）が IO を要求し、
    /// 純粋なテストで回せなくなるから。要るときは待ち方を引数で受ける形で足す。
    ///
    pub def withRetry(attempts: Int32, thunk: Unit -> a \ ef): a \ (ef - TransientDbErr) + DbErr =
        retryLoop(Int32.max(1, attempts), 1, thunk)

    ///
    /// attempt 回目を走らせ、Transient なら次へ。
    ///
    def retryLoop(attempts: Int32, attempt: Int32, thunk: Unit -> a \ ef): a \ (ef - TransientDbErr) + DbErr =
        match TransientDbErr.runWithResult(thunk) {
            case Ok(value) => value
            case Err(last) =>
                if (attempt >= attempts)
                    DbErr.retryExhausted("${last} after ${attempts} attempts")
                else
                    retryLoop(attempts, attempt + 1, thunk)
        }

}
