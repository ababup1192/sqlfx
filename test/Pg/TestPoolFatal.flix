///
/// fatal（OutOfMemoryError のような VirtualMachineError）でも接続が返る事を、実 PG と失敗を差し込む DataSource で見る
/// （設計 docs/design/cte-and-fatal.md の 2.5 / 2.7）。大きさ 1・借り待ち 300 ms のプールなので、1 本でも漏れれば次の借りは Timeout。
///
/// どの場面も 1 つの row にまとめて見る:
///
///   (結果, 表の row の数, 場面の後の active, 次の借り, 開いた物理接続の数, BEGIN の後に後始末の呼び出しがあったか)
///
///   結果:          投げ直された例外の class 名（COMMIT の最中なら " +CommitOutcomeUnknown"）か、値で返った時の "ok" / "other" / "err"
///   開いた物理接続: 次の借りまで含めて。1 なら同じ接続が返って使い回された、2 なら evict して作り直した
///   後始末:        ROLLBACK して返した接続は true、evict した接続は false（evict の後に本物の接続へ protocol を送らない）
///
mod TestPoolFatal {

    use Sqlfx.Db
    use Sqlfx.DbError
    use Sqlfx.DbWrite
    use Sqlfx.Pool
    use Sqlfx.RawSql
    use Sqlfx.Retry
    use Sqlfx.Sql
    use Sqlfx.Tx

    import java.lang.OutOfMemoryError
    import java.lang.RuntimeException
    import java.lang.Throwable
    import java.util.concurrent.CompletionException

    use Sqlfx.DbError.Failure

    /// 1 つの場面の結果。
    type alias Outcome = (String, Int32, Int32, String, Int32, Bool)

    /// 利用側の業務エラー（テスト用）。
    pub eff FatalBizErr {
        def fail(): Void
    }

    ///
    /// 新しいプールで場面を 1 つ走らせる。場面が投げた物は class 名に、値で返った物は `describe` にする。
    ///
    def measure(faults: FaultyDataSource.Faults, scene: FaultyDataSource.Faulty -> String \ IO): Outcome \ IO =
        let faulty = FaultyDataSource.open(faults);
        resetTable(faulty);
        let outcome = try {
            scene(faulty)
        } catch {
            case error: Throwable => thrownName(error)
        };
        let active = Pool.stats(faulty#pool)#active;
        let next = nextBorrow(faulty);
        let opened = FaultyDataSource.openedCount(faulty);
        let rows = countRows(faulty);
        let cleaned = FaultyDataSource.cleanedUpAfterBegin(1, faulty);
        Pool.close(faulty#pool);
        (outcome, rows, active, next, opened, cleaned)

    /// 投げた物の class 名。COMMIT の最中の marker（`Db.isCommitOutcomeUnknown`）があれば添える。
    def thrownName(error: Throwable): String \ IO =
        let name: String = error.getClass().getName();
        if (Db.isCommitOutcomeUnknown(error)) "${name} +CommitOutcomeUnknown" else name

    /// 値で返った結果を 1 語に。
    def describe(result: Result[Failure, a]): String = match result {
        case Ok(_)                                                 => "ok"
        case Err(Failure.Permanent(DbError.DbErrorKind.Other(_))) => "other"
        case Err(failure)                                          => DbError.describeFailure(failure)
    }

    /// 次の借り。"ok" か失敗の 1 語。
    def nextBorrow(faulty: FaultyDataSource.Faulty): String \ IO =
        RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(faulty#pool, _ -> Sql.fetch("SELECT 1", Nil) |> List.length)))
            |> describe

    /// 表の row の数。
    def countRows(faulty: FaultyDataSource.Faulty): Int32 \ IO =
        RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(faulty#pool, _ -> Sql.fetch("SELECT id FROM sqlfx_test_fatal", Nil) |> List.length)))
            |> Result.getWithDefault(-1)

    /// 表を作り直す。物理接続の数と呼び出しの記録には数えない（場面は新しいプールで始まる前提なので、ここだけ別のプールで）。
    def resetTable(_faulty: FaultyDataSource.Faulty): Unit \ IO =
        let pool = Pool.open({ maxConnections = 1, borrowTimeoutMs = 1000 | Pool.defaultConfig(pgConfig()) });
        discard RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withConnection(pool, _ -> {
            discard Sql.execute("DROP TABLE IF EXISTS sqlfx_test_fatal", Nil);
            discard Sql.execute("CREATE TABLE sqlfx_test_fatal (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL)", Nil)
        })));
        Pool.close(pool)

    /// 1 row 入れる。marker を渡すと SQL の後ろに付く。
    def insertRow(marker: String): Unit \ DbWrite + RawSql =
        discard Sql.execute("INSERT INTO sqlfx_test_fatal (name) VALUES ('x') /* inject: ${marker} */", Nil)

    def oom(): Throwable \ IO = checked_cast(new OutOfMemoryError("injected"))

    def runtime(): Throwable \ IO = checked_cast(new RuntimeException("injected"))

    def throwIt(error: Throwable): a \ IO = throw error

    /// 別の関数の中で SQL を出して投げる（TestCatchNesting の 9。Db.guard を飛ばす形）。
    def insertThenThrow(error: Throwable): Unit \ DbWrite + RawSql + IO =
        insertRow("none");
        throwIt(error)

    ///
    /// withLazyTx で thunk を走らせ、値で返った結果を 1 語に。
    ///
    /// WhyNot: RawSql.runWithAllow を withLazyTx の外に張らない。thunk が Tx の外の handler へ op を出すと、その後で投げた物は
    /// 形によって Pool の catch を全部飛ばし、接続が漏れる（testRawSqlOutsideTxLeaks）。ここでは保証できる形を見る。
    ///
    def lazyTx(faulty: FaultyDataSource.Faulty, thunk: Unit -> Unit \ ef): String \ (ef - {Sqlfx.SqlRead, Sqlfx.SqlWrite, Sqlfx.SqlSavepoint, Sqlfx.TransientDbErr, Sqlfx.DbErr, Sqlfx.RawSql}) + IO =
        DbError.runWithFailure(() -> Pool.withLazyTx(faulty#pool, () -> RawSql.runWithAllow(thunk))) |> describe

    def evicted(thrown: String): Outcome = (thrown, 0, 0, "ok", 2, false)

    ///
    /// 遅延 Tx の中の fatal（2.7 の 1〜4、6、7、9、20 と、Db.guard を飛ばす形）。どれも投げ直され、接続は evict される。
    ///
    ///   #   場面                                                               期待
    ///   1   thunk で INSERT → OOM                                              OOM、0 row、active 0、次は ok、作り直し、後始末無し
    ///   2   fatal-after-execute の INSERT                                      同上
    ///   3   fatal-on-prepare の文が Tx の最初の文                              同上
    ///   4   onBegin で OOM                                                     同上
    ///   6   Db.attempt(Tx.withSavepoint(Db.guard(INSERT → OOM)))               同上
    ///   7   6 から Db.guard を外す                                             同上
    ///   9   7 を thunk の中の RawSql.runWithAllow で包む                       同上
    ///   20  OOM を CompletionException で包んで投げる                          同上（class は CompletionException）
    ///   E1  別の関数の中で INSERT → OOM                                        同上
    ///   E2  record に入れた closure の中で INSERT → OOM                        同上
    ///
    @Test
    def testLazyTxFatalEvictsAndRethrows(): Unit \ {Assert, IO} =
        let none = FaultyDataSource.noFaults();
        let rows = List#{
            measure(none, faulty -> lazyTx(faulty, () -> { insertRow("none"); throwIt(oom()) })),
            measure(none, faulty -> lazyTx(faulty, () -> insertRow("fatal-after-execute"))),
            measure(none, faulty -> lazyTx(faulty, () -> discard Sql.fetch("SELECT 1 /* inject: fatal-on-prepare */", Nil))),
            measure(none, faulty -> DbError.runWithFailure(() -> Pool.withLazyTxAfterBegin(faulty#pool, () -> throwIt(oom()), () -> RawSql.runWithAllow(() -> insertRow("none")))) |> describe),
            measure(none, faulty -> lazyTx(faulty, () -> discard Db.attempt(() -> Tx.withSavepoint("sp", () -> Db.guard(() -> { insertRow("none"); throwIt(oom()) }))))),
            measure(none, faulty -> lazyTx(faulty, () -> discard Db.attempt(() -> Tx.withSavepoint("sp", () -> { insertRow("none"); throwIt(oom()) })))),
            measure(none, faulty -> lazyTx(faulty, () -> RawSql.runWithAllow(() -> discard Db.attempt(() -> Tx.withSavepoint("sp", () -> { insertRow("none"); throwIt(oom()) }))))),
            measure(none, faulty -> lazyTx(faulty, () -> { insertRow("none"); throwIt(checked_cast(new CompletionException(oom()))) })),
            measure(none, faulty -> lazyTx(faulty, () -> insertThenThrow(oom()))),
            measure(none, faulty -> { let holder = { call = () -> { insertRow("none"); throwIt(oom()) } }; lazyTx(faulty, holder#call) })
        };
        let fatal = evicted("java.lang.OutOfMemoryError");
        Assert.assertEq(
            expected = List#{fatal, fatal, fatal, fatal, fatal, fatal, fatal, evicted("java.util.concurrent.CompletionException"), fatal, fatal},
            rows)

    ///
    /// 遅延 Tx の中の fatal でない物（2.7 の 8、12、13、14、15、16 と、Db.guard を飛ばす形）。投げ直さず値にする。
    ///
    ///   #   場面                                                  期待
    ///   8   7 の OOM を RuntimeException に                       other、0 row、active 0、次は ok、同じ接続、ROLLBACK して返す
    ///   12  driver-runtime-after-execute                          other、0 row、active 0、作り直し（pgjdbc の中の例外は接続を捨てる）
    ///   13  runtime-after-execute                                 other、0 row、active 0、同じ接続、ROLLBACK して返す
    ///   14  thunk で RuntimeException                             8 と同じ
    ///   15  failSetAutoCommit（BEGIN の失敗）                     other、0 row、active 0、次は ok、作り直し（autocommit のままの
    ///       接続への ROLLBACK は失敗するので evict する）
    ///   16  failRollback で thunk が業務の Err                     err、0 row、active 0、作り直し（ROLLBACK の失敗は evict）
    ///   E3  別の関数の中で INSERT → RuntimeException              8 と同じ
    ///
    @Test
    def testLazyTxNonFatalBecomesValue(): Unit \ {Assert, IO} =
        let none = FaultyDataSource.noFaults();
        let rows = List#{
            measure(none, faulty -> lazyTx(faulty, () -> discard Db.attempt(() -> Tx.withSavepoint("sp", () -> { insertRow("none"); throwIt(runtime()) })))),
            measure(none, faulty -> lazyTx(faulty, () -> insertRow("driver-runtime-after-execute"))),
            measure(none, faulty -> lazyTx(faulty, () -> insertRow("runtime-after-execute"))),
            measure(none, faulty -> lazyTx(faulty, () -> { insertRow("none"); throwIt(runtime()) })),
            measure({ failSetAutoCommit = true | none }, faulty -> lazyTx(faulty, () -> insertRow("none"))),
            measure({ failRollback = true | none }, faulty ->
                DbError.runWithFailure(() -> Pool.withLazyTxResult(faulty#pool, () -> RawSql.runWithAllow(() -> { insertRow("none"); (Err("biz"): Result[String, Unit]) })))
                    |> (result -> match result {
                        case Ok(Err(_))    => "err"
                        case Ok(Ok(_))     => "ok"
                        case Err(failure)  => DbError.describeFailure(failure)
                    })),
            measure(none, faulty -> lazyTx(faulty, () -> insertThenThrow(runtime())))
        };
        let returned = ("other", 0, 0, "ok", 1, true);
        Assert.assertEq(
            expected = List#{returned, ("other", 0, 0, "ok", 2, false), returned, returned, ("other", 0, 0, "ok", 2, true), ("err", 0, 0, "ok", 2, true), returned},
            rows)

    ///
    /// handler の本体の fatal でない例外は、その SQL の失敗として thunk に値で返る（A）。thunk は Db.attempt で受けて続けられる。
    /// pgjdbc の中から出た物だけは、thunk が続けても COMMIT せずに接続を捨てる。
    ///
    ///   attempt(runtime-after-execute の INSERT) → 続けて Ok        ok、1 row（INSERT 自体は通っている）、同じ接続
    ///   attempt(driver-runtime-after-execute)   → 続けて Ok        other、0 row、作り直し
    ///
    @Test
    def testHandlerBodyNonFatalReturnsToThunk(): Unit \ {Assert, IO} =
        let none = FaultyDataSource.noFaults();
        let rows = List#{
            measure(none, faulty -> lazyTx(faulty, () -> discard Db.attempt(() -> insertRow("runtime-after-execute")))),
            measure(none, faulty -> lazyTx(faulty, () -> discard Db.attempt(() -> insertRow("driver-runtime-after-execute"))))
        };
        Assert.assertEq(expected = List#{("ok", 1, 0, "ok", 1, true), ("other", 0, 0, "ok", 2, false)}, rows)

    ///
    /// COMMIT の最中の fatal（2.7 の 11）。COMMIT が PG に届いたか分からないので、投げ直す fatal に marker が付く。
    /// 本物の commit の前で投げるので row は残らない。接続は evict する。後始末の欄が true なのは、失敗した commit の
    /// 呼び出しそのものが記録に入るため（その後に ROLLBACK は送らない）。
    ///
    @Test
    def testCommitFatalCarriesMarker(): Unit \ {Assert, IO} =
        let outcome = measure({ fatalOnCommit = true | FaultyDataSource.noFaults() }, faulty -> lazyTx(faulty, () -> insertRow("none")));
        Assert.assertEq(expected = ("java.lang.OutOfMemoryError +CommitOutcomeUnknown", 0, 0, "ok", 2, true), outcome)

    ///
    /// Retry の中の fatal（2.7 の 17）。1 回目は statement_timeout（Transient）で呼び直し、2 回目の OOM は呼び直さず投げる。
    /// 結果の欄に thunk を呼んだ回数を添える。
    ///
    @Test
    def testRetryDoesNotRetryFatal(): Unit \ {Assert, IO} =
        let calls = Ref.fresh(Static, 0);
        let outcome = measure(FaultyDataSource.noFaults(), faulty ->
            DbError.runWithFailure(() -> Retry.withRetry(3, () -> Pool.withLazyTx(faulty#pool, () -> RawSql.runWithAllow(() -> {
                Ref.put(Ref.get(calls) + 1, calls);
                if (Ref.get(calls) == 1) {
                    discard Sql.execute("SET LOCAL statement_timeout = 50", Nil);
                    discard Sql.fetch("SELECT pg_sleep(1)", Nil)
                } else {
                    insertRow("none");
                    throwIt(oom())
                }
            })))) |> describe);
        let (thrown, rowCount, active, next, _, _) = outcome;
        Assert.assertEq(expected = ("java.lang.OutOfMemoryError", 2, 0, 0, "ok"), (thrown, Ref.get(calls), rowCount, active, next))

    ///
    /// SQL を出さない thunk の fatal（2.7 の 10）。借りていないので evict する物が無い。プールに触らない。
    ///
    @Test
    def testFatalBeforeBorrowTouchesNothing(): Unit \ {Assert, IO} =
        let outcome = measure(FaultyDataSource.noFaults(), faulty -> lazyTx(faulty, () -> throwIt(oom())));
        Assert.assertEq(expected = ("java.lang.OutOfMemoryError", 0, 0, "ok", 1, false), outcome)

    ///
    /// Pool.withConnection の中（2.7 の 18、19）。autocommit なので INSERT は残る。
    ///
    ///   18a  thunk で INSERT → OOM                  OOM、1 row、active 0、作り直し
    ///   18b  fatal-after-execute の INSERT          同上
    ///   19   thunk で INSERT → RuntimeException     other、1 row、active 0、同じ接続
    ///
    @Test
    def testWithConnectionReturnsOnThrow(): Unit \ {Assert, IO} =
        let none = FaultyDataSource.noFaults();
        let rows = List#{
            measure(none, faulty -> withConnection(faulty, () -> { insertRow("none"); throwIt(oom()) })),
            measure(none, faulty -> withConnection(faulty, () -> insertRow("fatal-after-execute"))),
            measure(none, faulty -> withConnection(faulty, () -> { insertRow("none"); throwIt(runtime()) }))
        };
        Assert.assertEq(
            expected = List#{("java.lang.OutOfMemoryError", 1, 0, "ok", 2, false), ("java.lang.OutOfMemoryError", 1, 0, "ok", 2, false), ("other", 1, 0, "ok", 1, false)},
            rows)

    /// Pool.withConnection で thunk を走らせ、値で返った結果を 1 語に。
    def withConnection(faulty: FaultyDataSource.Faulty, thunk: Unit -> Unit \ ef): String \ (ef - {Sqlfx.SqlRead, Sqlfx.SqlWrite, Sqlfx.SqlSavepoint, Sqlfx.TransientDbErr, Sqlfx.DbErr, Sqlfx.RawSql}) + IO =
        DbError.runWithFailure(() -> Pool.withConnection(faulty#pool, _ -> RawSql.runWithAllow(thunk))) |> describe

    ///
    /// 利用側の handler の内側の Db.guard の fatal（2.7 の 5、設計の 2.1 の f）。Db.guard が投げ直した fatal は利用側の run の中で
    /// 投げられるので B には届かないが、op を受けた Pool の handler の所から出てきて E が拾い、evict する。
    ///
    @Test
    def testFatalInUserHandlerGuard(): Unit \ {Assert, IO} =
        let outcome = measure(FaultyDataSource.noFaults(), faulty ->
            DbError.runWithFailure(() -> Pool.withLazyTxResult(faulty#pool, () -> RawSql.runWithAllow(() ->
                run {
                    Ok(Db.guard(() -> { insertRow("none"); throwIt(oom()) }))
                } with handler FatalBizErr {
                    def fail(_resume) = Err("biz")
                }))) |> Result.map(_ -> ()) |> describe);
        Assert.assertEq(expected = ("java.lang.OutOfMemoryError", 0, 0, "ok", 2, false), outcome)

    ///
    /// fatal-after-execute を 20 回続けても、全部 OOM のまま投げ直され（NPE にすり替わらない）、接続は毎回返る（2.7 の 21）。
    ///
    @Test
    def testRepeatedFatalNeverTurnsIntoNpe(): Unit \ {Assert, IO} =
        let faulty = FaultyDataSource.open(FaultyDataSource.noFaults());
        resetTable(faulty);
        let thrown = List.range(0, 20) |> List.map(_ ->
            try {
                lazyTx(faulty, () -> insertRow("fatal-after-execute"))
            } catch {
                case error: Throwable => thrownName(error)
            });
        let active = Pool.stats(faulty#pool)#active;
        Pool.close(faulty#pool);
        Assert.assertEq(expected = (List.repeat(20, "java.lang.OutOfMemoryError"), 0), (thrown, active))


    ///
    /// thunk が Tx の外の handler へ op を出した後で投げると、Pool の catch に届かず接続が漏れる（直らない事の記録。設計の 2.3）。
    /// RawSql.runWithAllow を withLazyTx の外に張り、別の関数の中で SQL を出して投げる形。
    ///
    ///   [RawSql の handler [withLazyTx [ INSERT（RawSql.allow が外へ）; OOM ]]] → OOM は抜けるが、active 1、次は Timeout
    ///
    @Test
    def testRawSqlOutsideTxLeaks(): Unit \ {Assert, IO} =
        let outcome = measure(FaultyDataSource.noFaults(), faulty ->
            RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(faulty#pool, () -> insertThenThrow(oom())))) |> describe);
        Assert.assertEq(expected = ("java.lang.OutOfMemoryError", -1, 1, "timeout 0", 1, false), outcome)

}
