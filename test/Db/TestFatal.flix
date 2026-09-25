///
/// fatal の判定（`Db.isFatal`）と、pgjdbc の中から出た例外の判定（`Db.fromDriver`）。DB 無し。
///
mod TestFatal {

    use Sqlfx.Db

    import java.lang.IllegalStateException
    import java.lang.InternalError
    import java.lang.OutOfMemoryError
    import java.lang.RuntimeException
    import java.lang.StackOverflowError
    import java.lang.StackTraceElement
    import java.lang.Throwable
    import java.util.concurrent.CompletionException
    import org.postgresql.util.PSQLException
    import org.postgresql.util.PSQLState

    /// cause を depth 段だけ RuntimeException で包む。
    def wrapped(depth: Int32, inner: Throwable): Throwable \ IO =
        if (depth <= 0) inner
        else wrapped(depth - 1, checked_cast(new RuntimeException("wrap", inner)))

    def oom(): Throwable \ IO = checked_cast(new OutOfMemoryError("x"))

    def stackOverflow(): Throwable \ IO = checked_cast(new StackOverflowError("x"))

    ///
    /// 飲み込んではいけない物か。例外自身と、cause の連鎖を深さ 8 まで。
    ///
    ///   例外                                              → 期待
    ///   OutOfMemoryError                                  → true
    ///   InternalError                                     → true
    ///   StackOverflowError                                → false（1 つの Tx の深い再帰。巻き戻せば続けられる）
    ///   RuntimeException                                  → false
    ///   CompletionException(cause = OutOfMemoryError)     → true（graphql-java が包んで投げ返す形）
    ///   RuntimeException を 8 段重ねた奥に OutOfMemoryError → true（深さ 8 まで見る）
    ///   9 段重ねた奥に OutOfMemoryError                    → false
    ///   RuntimeException(cause = StackOverflowError)      → false
    ///
    @Test
    def testIsFatalTable(): Unit \ {Assert, IO} =
        let table: List[(Throwable, Bool)] = List#{
            (oom(), true),
            (checked_cast(new InternalError("x")), true),
            (stackOverflow(), false),
            (checked_cast(new RuntimeException("x")), false),
            (checked_cast(new CompletionException(oom())), true),
            (wrapped(8, oom()), true),
            (wrapped(9, oom()), false),
            (wrapped(1, stackOverflow()), false)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(Db.isFatal))

    /// stack trace の先頭を className の frame 1 つにした IllegalStateException。
    def thrownAt(className: String): Throwable \ IO =
        let error = new IllegalStateException("x");
        let frames: Array[StackTraceElement, Static] = Array#{new StackTraceElement(className, "m", "F.java", 1)} @ Static;
        error.setStackTrace(frames);
        checked_cast(error)

    /// pgjdbc の例外。
    def psqlException(): Throwable \ IO =
        let state: PSQLState = PSQLState.UNKNOWN_STATE;
        checked_cast(new PSQLException("x", state))

    /// stack trace の無い IllegalStateException。
    def withoutFrames(): Throwable \ IO =
        let error = new IllegalStateException("x");
        let frames: Array[StackTraceElement, Static] = Array#{} @ Static;
        error.setStackTrace(frames);
        checked_cast(error)

    ///
    /// pgjdbc の中から出たか。例外の class 名か、stack trace の先頭の frame の class 名が `org.postgresql.` で始まる物。
    ///
    ///   例外                                                          → 期待
    ///   先頭の frame が org.postgresql.core.v3.QueryExecutorImpl       → true（protocol の途中で出た物）
    ///   先頭の frame が Sqlfx.JdbcConvert                              → false（sqlfx 側の変換の失敗）
    ///   先頭の frame が org.postgresqlx.Other                          → false（区切りの `.` まで見る）
    ///   stack trace が無い                                             → false
    ///   PSQLException                                                  → true（class 名）
    ///
    @Test
    def testFromDriverTable(): Unit \ {Assert, IO} =
        let table: List[(Throwable, Bool)] = List#{
            (thrownAt("org.postgresql.core.v3.QueryExecutorImpl"), true),
            (thrownAt("Sqlfx.JdbcConvert"), false),
            (thrownAt("org.postgresqlx.Other"), false),
            (withoutFrames(), false),
            (psqlException(), true)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(Db.fromDriver))

    /// catchAll は fatal も値にする（投げ直すかは受けた側が決める）。
    @Test
    def testCatchAllKeepsFatalAsValue(): Unit \ {Assert, IO} =
        let caught = Db.catchAll(() -> { throw new OutOfMemoryError("x"); 1 }) |> Result.isErr;
        Assert.assertEq(expected = true, caught)

}
