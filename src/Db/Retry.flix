mod Retry {

    import java.lang.Thread
    import java.lang.InterruptedException

    ///
    /// 再実行の方針。
    ///
    /// - `attempts`: 呼ぶ回数の上限（最初の 1 回を含む）。1 未満は 1
    /// - `baseMs`: 1 回目の失敗の後の待ちの上限。失敗のたびに 2 倍になる
    /// - `maxMs`: 待ちの上限の頭打ち
    ///
    pub type alias Policy = { attempts = Int32, baseMs = Int32, maxMs = Int32 }

    ///
    /// 既定の方針。3 回、100 ms から 2 倍ずつ、2 秒で頭打ち。
    ///
    /// WhyNot: 3 回より多くしないのは、DB の再起動（数秒）を跨ぐのが目的で、それより長い障害は
    /// 呼び出し側（HTTP の 503 と、その先の再試行）に任せる方が、接続を待つスレッドを溜めないため。
    /// 100 ms から始めるのは、デッドロックのような一瞬の競合なら最初の待ちだけで通るように。
    ///
    pub def defaultPolicy(): Policy =
        { attempts = 3, baseMs = 100, maxMs = 2000 }

    ///
    /// TransientDbErr で失敗したら thunk を最初から呼び直す。attempts 回すべて失敗したら DbErr.retryExhausted。attempts が 1 未満なら 1 回。
    /// 待たずに即呼び直す。DB の再起動を跨ぎたいなら `withRetryWith`。
    /// thunk は Tx 単位（`withTx` ごと）で渡す。PG はデッドロック後に Tx 全体が aborted になるので、文単位の再実行は意味を持たない。
    ///
    pub def withRetry(attempts: Int32, thunk: Unit -> a \ ef): a \ (ef - TransientDbErr) + DbErr =
        withRetryWith({ attempts = attempts, baseMs = 0, maxMs = 0 }, _ -> (), () -> 0.0, thunk)

    ///
    /// `withRetry` に加えて、失敗のたびに `wait(backoffMs(policy, attempt, jitter()))` してから呼び直す。最後の失敗の後は待たない。
    /// 本番は `withRetryWith(defaultPolicy(), sleepMs, () -> Math.Random.randomFloat64(), thunk)` のように、待つ手段と乱数を渡す。
    ///
    /// WhyNot: wait と jitter を中で Thread.sleep と乱数に決めないのは、そうすると IO が付いて
    /// 純粋なテストで回せなくなるため。テストは待った ms を記録するだけの wait と固定の jitter を渡す。
    ///
    pub def withRetryWith(policy: Policy, wait: Int32 -> Unit \ ef2, jitter: Unit -> Float64 \ ef3, thunk: Unit -> a \ ef): a \ (ef - TransientDbErr) + ef2 + ef3 + DbErr =
        retryLoop(policy, Int32.max(1, policy#attempts), 1, wait, jitter, thunk)

    ///
    /// attempt 回目を走らせ、Transient なら待って次へ。
    ///
    def retryLoop(policy: Policy, attempts: Int32, attempt: Int32, wait: Int32 -> Unit \ ef2, jitter: Unit -> Float64 \ ef3, thunk: Unit -> a \ ef): a \ (ef - TransientDbErr) + ef2 + ef3 + DbErr =
        match TransientDbErr.runWithResult(thunk) {
            case Ok(value) => value
            case Err(last) =>
                if (attempt >= attempts)
                    DbErr.retryExhausted("${last} after ${attempts} attempts")
                else {
                    wait(backoffMs(policy, attempt, jitter()));
                    retryLoop(policy, attempts, attempt + 1, wait, jitter, thunk)
                }
        }

    ///
    /// attempt 回目（1 始まり）の失敗の後に待つ ms。full jitter: 上限 `min(maxMs, baseMs * 2^(attempt-1))` に jitter（0.0〜1.0）を掛ける。
    /// attempt が 1 未満は 1、jitter は 0.0〜1.0 に丸める、baseMs / maxMs が負なら 0。
    ///
    /// WhyNot: 上限そのものを待つ（jitter 無しの指数）にしないのは、同時に失敗したリクエストが
    /// 同じ時刻に揃って呼び直し、DB が起き上がった瞬間にまた詰まるのを避けるため。
    ///
    pub def backoffMs(policy: Policy, attempt: Int32, jitter: Float64): Int32 =
        let cap = capMs(Int32.max(0, policy#baseMs), Int32.max(0, policy#maxMs), Int32.max(1, attempt) - 1);
        let ratio = Float64.max(0.0, Float64.min(1.0, jitter));
        Float64.clampToInt32(min = 0, max = cap, nanValue = 0, Float64.floor(Int32.toFloat64(cap) * ratio))

    ///
    /// `min(maxMs, baseMs * 2^exponent)`。2 倍にしながら maxMs に届いたら止めるので、exponent が大きくてもオーバーフローしない。
    ///
    def capMs(baseMs: Int32, maxMs: Int32, exponent: Int32): Int32 =
        def double(current: Int32, remaining: Int32): Int32 =
            if (remaining <= 0 or current >= maxMs or current <= 0) Int32.min(current, maxMs)
            else if (current > maxMs / 2) maxMs
            else double(current * 2, remaining - 1);
        double(baseMs, exponent)

    ///
    /// `withRetryWith` の wait に渡す Thread.sleep。割り込まれたら残りを待たずに戻る（呼び直す側が次の失敗で気付く）。
    ///
    pub def sleepMs(ms: Int32): Unit \ IO =
        if (ms <= 0) ()
        else
            try {
                Thread.sleep(Int32.toInt64(ms))
            } catch {
                case _: InterruptedException => ()
            }

}
