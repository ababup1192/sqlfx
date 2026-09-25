///
/// sqlfx が利用側の thunk を包んで handler を張る所（設計の D）は、その `run` の直下で例外を拾い、`run` を抜けてから
/// 同じ物を投げ直す。そうしないと、thunk が外の handler へ op を投げた後で投げた物は、外側の catch（`Pool.withLazyTx` の
/// `Db.guard`）を素通りする（TestCatchNesting の 4 番目の形）。
///
///   外の handler [ Db.catchAll [ 包む関数 [ outer(); throw ] ] ]
///     → Db.catchAll が受ける（素通りして外の try に届く物は 0）。投げ直した物は元の物のまま（値にしない・包まない）
///
mod TestRethrowUnderRun {

    use Sqlfx.Db
    use Sqlfx.DbErr
    use Sqlfx.DbError
    use Sqlfx.DbTest
    use Sqlfx.RawSql
    use Sqlfx.Retry
    use Sqlfx.TimeZone
    use Sqlfx.TransientDbErr
    use Sqlfx.Tx
    use Sqlfx.Zone

    import java.lang.{Object => JObject}
    import java.lang.OutOfMemoryError
    import java.lang.RuntimeException
    import java.lang.Throwable

    pub eff Outer {
        def outer(): Unit
    }

    /// 外側の handler（再開する）。
    def withOuter(thunk: Unit -> a \ ef): a \ ef - Outer =
        run thunk() with handler Outer { def outer(resume) = resume(()) }

    ///
    /// 包む関数の中で外の handler へ op を投げてから `error` を投げる。すぐ外の `Db.catchAll` が受ければ
    /// "caught <message>"、それを素通りして一番外の try に届けば "escaped"。
    ///
    def measure(wrap: (Unit -> Unit \ {Outer, IO}) -> Unit \ {Outer, IO}, error: Throwable): String \ IO =
        try {
            withOuter(() -> match Db.catchAll(() -> wrap(() -> { TestRethrowUnderRun.Outer.outer(); throw error })) {
                case Ok(())    => "not thrown"
                case Err(seen) => {
                    let message: String = seen.getMessage();
                    if (Object.isNull(message) or not sameObject(seen, error)) "caught another" else "caught ${message}"
                }
            })
        } catch {
            case _: Throwable => "escaped"
        }

    /// 同じ物（参照が同じ）か。Throwable の equals は参照の比較。
    def sameObject(left: Throwable, right: Throwable): Bool \ IO =
        let leftObject: JObject = checked_cast(left);
        let rightObject: JObject = checked_cast(right);
        leftObject.equals(rightObject)

    ///
    /// 包む関数ごとに、RuntimeException と OutOfMemoryError のどちらも、すぐ外の catch に同じ物が届く（値にしない・包まない）。
    ///
    ///   包む関数                       RuntimeException          OutOfMemoryError
    ///   DbError.runWithKind            caught                    caught
    ///   DbError.runWithFailure         caught                    caught
    ///   Db.attempt                     caught                    caught
    ///   DbError.onConstraintWith       caught                    caught
    ///   Tx.withSavepoint               caught                    caught
    ///   Retry.withRetry                escaped                   escaped（retryLoop の自己再帰が経路に挟まる。TestCatchNesting の 9）
    ///   Retry.withRetryWith            escaped                   escaped（同上。Retry が包む Pool.withLazyTx の中は E が受ける）
    ///   RawSql.runWithAllow            caught                    caught
    ///   DbErr.runWithResult            caught                    caught
    ///   TransientDbErr.runWithResult   caught                    caught
    ///   TimeZone.runWith               caught                    caught
    ///
    @Test
    def testWrappersRethrowAfterRun(): Unit \ {Assert, IO} =
        // WhyNot: 包む関数を List に入れて回さない。List / record / Ref から取り出した closure の中で op の後に投げると、
        // 間の catch を全部飛ばして op を受けた handler の所に出てくる（TestCatchNesting の 9）。ここで見たいのは D の形そのもの
        let both = (wrap: (Unit -> Unit \ {Outer, IO}) -> Unit \ {Outer, IO}) -> (measure(wrap, runtime()), measure(wrap, fatal()));
        let rows = List#{
            both(thunk -> discard DbError.runWithKind(thunk)),
            both(thunk -> discard DbError.runWithFailure(thunk)),
            both(thunk -> discard Db.attempt(thunk)),
            both(thunk -> discard DbError.runWithKind(() -> DbError.onConstraintWith(_ -> None, (_: String) -> (), thunk))),
            both(thunk -> discard DbError.runWithKind(() -> DbTest.runWithRows(Nil, () -> Tx.withSavepoint("sp", thunk)))),
            both(thunk -> discard DbError.runWithKind(() -> Retry.withRetry(3, thunk))),
            both(thunk -> discard DbError.runWithKind(() -> Retry.withRetryWith(Retry.defaultPolicy(), _ -> (), () -> 0.0, thunk))),
            both(thunk -> RawSql.runWithAllow(thunk)),
            both(thunk -> discard DbErr.runWithResult(thunk)),
            both(thunk -> discard TransientDbErr.runWithResult(thunk)),
            both(thunk -> TimeZone.runWith(Zone.utc(), thunk))
        };
        let caught = ("caught runtime", "caught fatal");
        let escaped = ("escaped", "escaped");
        Assert.assertEq(expected = List#{caught, caught, caught, caught, caught, escaped, escaped, caught, caught, caught, caught}, rows)

    def runtime(): Throwable \ IO = checked_cast(new RuntimeException("runtime"))

    def fatal(): Throwable \ IO = checked_cast(new OutOfMemoryError("fatal"))

    /// Retry は Transient でない例外で呼び直さない（投げ直すだけ）。thunk を呼んだ回数は 1。
    @Test
    def testRetryDoesNotRetryRethrown(): Unit \ {Assert, IO} =
        let calls = Ref.fresh(Static, 0);
        discard Db.catchAll(() -> DbError.runWithKind(() -> Retry.withRetry(3, () -> {
            Ref.put(Ref.get(calls) + 1, calls);
            throw new RuntimeException("once")
        })));
        Assert.assertEq(expected = 1, Ref.get(calls))

}
