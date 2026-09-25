///
/// try / catch と `run … with handler` の入れ子で、中で飛んだ JVM の例外がどこで受かるか（実測の表。設計 docs/design/cte-and-fatal.md の 2.2）。
/// fatal の後始末（Pool の A / B / C / D の catch）はこの表を前提に置いてある。コンパイラを上げたら最初にこれを回す。
///
///   #  形                                                                    受かるか
///   1  try { run { op(内側の handler へ); throw } }                           受かる
///   2  run { try { op(外側の handler へ); throw } }                           受かる
///   3  run { try { run { op(外側へ) }; throw } }                              受かる
///   4  run { try { run { op(外側へ); throw } } }                              素通り
///   5  run { try { op } } with handler { def op = throw }                      素通り
///   6  handler の本体の中の try で投げる（thunk が外の handler に op を投げた後でも）  受かる
///   7  handler の本体の try の中で resume し、その先で thunk が投げる             形による（下の 7 の表）。どちらでも本体の try は網にならない
///   8  run { Ok(catchAll(thunk)) } の直下で拾い、run を抜けてから投げ直す       受かる（4 の形でも外の try に届く）
///   9  op と throw を別の関数に書く、または op を受けた handler と throw の間に catch を直下に持たない run・
///      自己再帰の関数・record / Ref / List から取り出した closure の呼び出しがある   間の try を全部飛ばす（下の 9 の表）
///  10  9 の形で、op を受けた handler の run を外から包む try                      受かる
///
mod TestCatchNesting {

    import java.lang.OutOfMemoryError
    import java.lang.Throwable

    pub eff Outer {
        def outer(): Unit
    }

    pub eff Inner {
        def inner(): Unit
    }

    /// handler の本体で拾えたかを返す op。
    pub eff Probe {
        def probe(): String
    }

    /// try / catch。受かれば Err("caught")。
    def attempt(thunk: Unit -> Unit \ ef): Result[String, Unit] \ ef =
        try {
            Ok(thunk())
        } catch {
            case _: Throwable => Err("caught")
        }

    /// Throwable を値にする（設計の D の形の catch）。
    def catchAll(thunk: Unit -> a \ ef): Result[Throwable, a] \ ef =
        try {
            Ok(thunk())
        } catch {
            case error: Throwable => Err(error)
        }

    def blow(): Unit \ IO =
        throw new OutOfMemoryError("injected")

    /// 外側の handler（再開する）。
    def withOuter(thunk: Unit -> a \ ef): a \ ef - Outer =
        run thunk() with handler Outer { def outer(resume) = resume(()) }

    /// 内側の handler（再開する）。
    def withInner(thunk: Unit -> a \ ef): a \ ef - Inner =
        run thunk() with handler Inner { def inner(resume) = resume(()) }

    /// 1〜5: 表の上の 5 行。受かった所に Err("caught")、素通りした所は外側の try が受け、内側の記録は "not reached" のまま。
    @Test
    def testCatchNestingTable(): Unit \ {Assert, IO} =
        let fourth = Ref.fresh(Static, "not reached");
        let fifth = Ref.fresh(Static, "not reached");
        let rows = List#{
            attempt(() -> withInner(() -> { TestCatchNesting.Inner.inner(); blow() })),
            withOuter(() -> attempt(() -> { TestCatchNesting.Outer.outer(); blow() })),
            withOuter(() -> attempt(() -> { withInner(() -> TestCatchNesting.Outer.outer()); blow() })),
            attempt(() -> withOuter(() -> {
                let caught = attempt(() -> withInner(() -> { TestCatchNesting.Outer.outer(); blow() }));
                Ref.put("inner ${caught}", fourth)
            })),
            attempt(() -> run {
                let caught = attempt(() -> TestCatchNesting.Outer.outer());
                Ref.put("inner ${caught}", fifth)
            } with handler Outer { def outer(resume) = { blow(); resume(()) } })
        };
        Assert.assertEq(
            expected = (List.repeat(5, Err("caught")), "not reached", "not reached"),
            (rows, Ref.get(fourth), Ref.get(fifth)))

    /// 6: handler の本体の中に try を置けば、thunk が外の handler に op を投げた後でも本体の throw を拾える。
    ///
    ///   withOuter [ Probe の handler: 本体 = catchAll(blow) → resume(拾えたか) [ outer(); probe() ] ]
    @Test
    def testTryInsideHandlerBodyCatches(): Unit \ {Assert, IO} =
        let seen = withOuter(() -> run {
            TestCatchNesting.Outer.outer();
            TestCatchNesting.Probe.probe()
        } with handler Probe {
            def probe(resume) = {
                let caught = catchAll(() -> blow()) |> Result.isErr;
                resume(if (caught) "caught in handler body" else "not caught")
            }
        });
        Assert.assertEq(expected = "caught in handler body", seen)

    /// 7: handler の本体の try の中で resume した時、その先で thunk が投げた物がその try に届くか。
    /// resume の後で thunk が外の handler へ op を投げると素通りし、投げなければ本体の try が thunk の例外まで拾う。
    /// 拾うかどうかが thunk の書き方で変わり、拾った時は利用側の例外を handler が飲み込むので、resume は try の外で呼ぶ。
    ///
    ///   thunk                                   本体の try   外の try
    ///   a. inner(); throw                       拾う         届かない
    ///   b. outer(); inner(); throw              拾う         届かない
    ///   c. inner(); outer(); throw              素通り       拾う
    @Test
    def testResumeInsideTryInHandlerBodyTable(): Unit \ {Assert, IO} =
        let measure = (thunk: Unit -> Unit \ {Inner, Outer, IO}) -> {
            let inBody = Ref.fresh(Static, "not reached");
            let outer = attempt(() -> withOuter(() -> run thunk() with handler Inner {
                def inner(resume) =
                    try {
                        resume(())
                    } catch {
                        case _: Throwable => Ref.put("caught in handler body", inBody)
                    }
            }));
            (Ref.get(inBody), outer)
        };
        let rows = List#{
            measure(() -> { TestCatchNesting.Inner.inner(); blow() }),
            measure(() -> { TestCatchNesting.Outer.outer(); TestCatchNesting.Inner.inner(); blow() }),
            measure(() -> { TestCatchNesting.Inner.inner(); TestCatchNesting.Outer.outer(); blow() })
        };
        Assert.assertEq(
            expected = List#{("caught in handler body", Ok(())), ("caught in handler body", Ok(())), ("not reached", Err("caught"))},
            rows)

    /// 8: 4 の形（外へ op を通した run の中で throw）でも、その run の直下で拾って run を抜けてから投げ直せば外の try に届く。
    ///
    ///   withOuter [ attempt [ run { Ok(catchAll([ outer(); throw ])) } with Inner の handler; Err なら投げ直す ] ]
    @Test
    def testCatchDirectlyUnderRunAndRethrowReachesOuterTry(): Unit \ {Assert, IO} =
        let rethrown = withOuter(() -> attempt(() -> {
            let outcome = run {
                catchAll(() -> { TestCatchNesting.Outer.outer(); TestCatchNesting.Inner.inner(); blow() })
            } with handler Inner { def inner(resume) = resume(()) };
            match outcome {
                case Ok(value)  => value
                case Err(error) => throw error
            }
        }));
        Assert.assertEq(expected = Err("caught"), rethrown)

    /// catch を直下に持たない run（利用側の handler の形）。
    pub eff Plain {
        def plain(): Unit
    }

    def withPlain(thunk: Unit -> a \ ef): a \ ef - Plain =
        run thunk() with handler Plain { def plain(resume) = resume(()) }

    /// 自己再帰を n 段挟んでから thunk を呼ぶ。
    def recursing(n: Int32, thunk: Unit -> a \ ef): a \ ef =
        if (n <= 0) thunk() else recursing(n - 1, thunk)

    /// record に入れてから取り出した closure。
    def viaRecord(thunk: Unit -> Unit \ ef): Unit -> Unit \ ef =
        let holder = { call = thunk };
        holder#call

    /// Ref に入れてから取り出した closure。
    def viaRef(thunk: Unit -> Unit \ ef): (Unit -> Unit \ ef) \ IO =
        Ref.get(Ref.fresh(Static, thunk))

    ///
    /// Pool の形: 外の try [ Inner の handler（Pool の SqlWrite の役）[ 内の try（Db.guard の役）[ 利用側の thunk ] ] ]。
    /// 受けた所を返す: "inner"（内の try）/ "around"（handler の run を外から包む try）/ "escaped"（どちらも飛ばした）。
    ///
    def poolShape(user: Unit -> Unit \ {Inner, Outer, IO}): String \ IO =
        try {
            withOuter(() ->
                try {
                    let outcome = run { catchAll(user) } with handler Inner { def inner(resume) = resume(()) };
                    match outcome { case Ok(_) => "none" case Err(_) => "inner" }
                } catch {
                    case _: Throwable => "around"
                })
        } catch {
            case _: Throwable => "escaped"
        }

    def toInner(): Unit \ {Inner, IO} = { TestCatchNesting.Inner.inner(); blow() }

    def toOuter(): Unit \ {Outer, IO} = { TestCatchNesting.Outer.outer(); blow() }

    ///
    /// 9 / 10: 経路に挟まる物ごとに、op の後に投げた物がどこで受かるか。
    /// 飛ばした時は、op を受けた handler の run の所に出てくる（その run を外から包む try が受ける）。
    /// op を受けたのが Pool の外の handler（Outer）なら、Pool の中のどの try にも届かない。
    /// 値は正しく戻る（飛ばすのは例外だけ。下の testShapesThatSkipCatchesKeepValues）。
    ///
    ///   挟まる物                        op → Inner（Pool の中）   op → Outer（Pool の外）
    ///   無し（op と throw を lambda に直に書く）  inner            inner
    ///   op と throw を別の関数に書く     around                    escaped
    ///   catch を直下に持たない run       around                   escaped
    ///   自己再帰の関数                  around                    escaped
    ///   record から取り出した closure    around                    escaped
    ///   Ref から取り出した closure       around                    escaped
    ///
    @Test
    def testShapesThatSkipCatchesTable(): Unit \ {Assert, IO} =
        let rows = List#{
            (poolShape(() -> { TestCatchNesting.Inner.inner(); blow() }), poolShape(() -> { TestCatchNesting.Outer.outer(); blow() })),
            (poolShape(() -> toInner()), poolShape(() -> toOuter())),
            (poolShape(() -> withPlain(() -> toInner())), poolShape(() -> withPlain(() -> toOuter()))),
            (poolShape(() -> recursing(2, () -> toInner())), poolShape(() -> recursing(2, () -> toOuter()))),
            (poolShape(viaRecord(() -> toInner())), poolShape(viaRecord(() -> toOuter()))),
            (poolShape(viaRef(() -> toInner())), poolShape(viaRef(() -> toOuter())))
        };
        Assert.assertEq(
            expected = List#{("inner", "inner"), ("around", "escaped"), ("around", "escaped"), ("around", "escaped"), ("around", "escaped"), ("around", "escaped")},
            rows)

    /// 9 の形でも、例外を投げなければ値は正しく戻る（内の try の Ok を通って、run の外まで）。
    @Test
    def testShapesThatSkipCatchesKeepValues(): Unit \ {Assert, IO} =
        let holder = { call = () -> { TestCatchNesting.Inner.inner(); 10 } };
        let outcome = run { catchAll(() -> holder#call() + 1) } with handler Inner { def inner(resume) = resume(()) };
        Assert.assertEq(expected = Ok(11), Result.mapErr(_ -> "thrown", outcome))

}
