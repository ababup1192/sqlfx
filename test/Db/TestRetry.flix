// Retry: Transient を捕まえて thunk を呼び直す（DB 無し）。

/// 2 回 Transient で失敗して 3 回目で成功する thunk は、attempts = 3 なら成功する。
///
///   attempt 1: deadlock
///   attempt 2: deadlock
///   attempt 3: Ok
@Test
def testRetrySucceedsWithinAttempts(): Unit \ Assert =
    let (result, calls): (Result[DbError.Failure, String], Int32) = region rc {
        let counter = Ref.fresh(rc, 0);
        let thunk = () -> {
            Ref.put(Ref.get(counter) + 1, counter);
            if (Ref.get(counter) < 3) TransientDbErr.deadlock() else "ok"
        };
        (DbError.runWithFailure(() -> Retry.withRetry(3, thunk)), Ref.get(counter))
    };
    Assert.assertEq(expected = (Ok("ok"), 3), (result, calls))

/// attempts 回すべて失敗したら DbErr.retryExhausted。Transient は外へ漏れない。
@Test
def testRetryExhaustedBecomesDbErr(): Unit \ Assert =
    let result = DbError.runWithFailure(() -> Retry.withRetry(2, () -> TransientDbErr.timeout(500)));
    Assert.assertEq(expected = Err(DbError.Failure.Permanent(DbError.DbErrorKind.RetryExhausted(DbError.TransientKind.Timeout(500), 2))), result |> Result.map(_ -> ()))

/// DbErr は再試行しない（1 回で外へ出る）。
@Test
def testRetryDoesNotRetryDbErr(): Unit \ Assert =
    let (result, calls): (Result[DbError.Failure, Unit], Int32) = region rc {
        let counter = Ref.fresh(rc, 0);
        let thunk = () -> {
            Ref.put(Ref.get(counter) + 1, counter);
            DbErr.uniqueViolation("users_email_key")
        };
        (DbError.runWithFailure(() -> Retry.withRetry(3, thunk)), Ref.get(counter))
    };
    Assert.assertEq(expected = (Err(DbError.Failure.Permanent(DbError.DbErrorKind.UniqueViolation("users_email_key"))), 1), (result |> Result.map(_ -> ()), calls))

/// attempts が 1 未満でも 1 回は走り、枯渇のメッセージも 1 回と言う。
@Test
def testRetryAttemptsBelowOneRunsOnce(): Unit \ Assert =
    let result: Result[DbError.Failure, Unit] = DbError.runWithFailure(() -> Retry.withRetry(0, () -> TransientDbErr.deadlock()));
    Assert.assertEq(expected = Err(DbError.Failure.Permanent(DbError.DbErrorKind.RetryExhausted(DbError.TransientKind.Deadlock, 1))), result)

// ---- backoff と jitter（DB 無し・純粋） ----

/// 待つ ms を記録するだけの wait。
def recordWait(log: Ref[List[Int32], r]): Int32 -> Unit \ r =
    ms -> Ref.put(ms :: Ref.get(log), log)

/// backoffMs は full jitter: 上限 min(maxMs, baseMs * 2^(attempt-1)) に jitter を掛ける。
///
///   base 100 / max 2000    jitter 0    0.5    1.0
///   attempt 1  (上限  100)        0     50    100
///   attempt 2  (上限  200)        0    100    200
///   attempt 3  (上限  400)        0    200    400
///   attempt 4  (上限  800)        0    400    800
///   attempt 5  (上限 1600)        0    800   1600
///   attempt 6  (上限 2000 で頭打ち)  0   1000   2000
@Test
def testBackoffMsTable(): Unit \ Assert =
    let policy = { attempts = 3, baseMs = 100, maxMs = 2000 };
    let inputs = List.range(1, 7) |> List.flatMap(attempt -> List#{(attempt, 0.0), (attempt, 0.5), (attempt, 1.0)});
    let expected = List#{0, 50, 100, 0, 100, 200, 0, 200, 400, 0, 400, 800, 0, 800, 1600, 0, 1000, 2000};
    Assert.assertEq(expected = expected, inputs |> List.map(pair -> { let (attempt, jitter) = pair; Retry.backoffMs(policy, attempt, jitter) }))

/// 境界: attempt が 1 未満は 1 と同じ、jitter は 0.0〜1.0 に丸める、大きな attempt でもオーバーフローせず maxMs で止まる、負の base / max は 0。
///
///   (attempt, jitter, baseMs, maxMs) → ms
@Test
def testBackoffMsBoundaries(): Unit \ Assert =
    let cases = List#{
        ((0, 1.0, 100, 2000), 100),
        ((-5, 1.0, 100, 2000), 100),
        ((1, -1.0, 100, 2000), 0),
        ((1, 2.0, 100, 2000), 100),
        ((40, 1.0, 100, 2000), 2000),
        ((1000000, 0.5, 100, 2000), 1000),
        ((3, 1.0, 100, 50), 50),
        ((1, 1.0, -100, 2000), 0),
        ((1, 1.0, 100, -1), 0),
        ((32, 1.0, 1, Int32.maxValue()), Int32.maxValue())
    };
    let actual = cases |> List.map(pair -> {
        let ((attempt, jitter, baseMs, maxMs), _) = pair;
        Retry.backoffMs({ attempts = 3, baseMs = baseMs, maxMs = maxMs }, attempt, jitter)
    });
    Assert.assertEq(expected = cases |> List.map(snd), actual)

/// 失敗 → 待つ → 呼び直す → 成功。待った ms は attempt 1、2 の backoff（jitter 固定 1.0 で上限そのもの）。
///
///   attempt 1: deadlock → wait 100
///   attempt 2: deadlock → wait 200
///   attempt 3: Ok       → 待たない
@Test
def testRetryWithWaitsBetweenAttempts(): Unit \ Assert =
    let (result, waits): (Result[DbError.Failure, String], List[Int32]) = region rc {
        let counter = Ref.fresh(rc, 0);
        let log = Ref.fresh(rc, Nil);
        let thunk = () -> {
            Ref.put(Ref.get(counter) + 1, counter);
            if (Ref.get(counter) < 3) TransientDbErr.deadlock() else "ok"
        };
        let outcome = DbError.runWithFailure(() -> Retry.withRetryWith(Retry.defaultPolicy(), recordWait(log), () -> 1.0, thunk));
        (outcome, Ref.get(log) |> List.reverse)
    };
    Assert.assertEq(expected = (Ok("ok"), List#{100, 200}), (result, waits))

/// attempts 回すべて失敗したら retryExhausted。最後の失敗の後は待たない（待ちは attempts - 1 回）。
///
///   attempt 1: timeout → wait 100
///   attempt 2: timeout → wait 200
///   attempt 3: timeout → retryExhausted（待たない）
@Test
def testRetryWithExhaustedDoesNotWaitAfterLast(): Unit \ Assert =
    let (result, waits): (Result[DbError.Failure, Unit], List[Int32]) = region rc {
        let log = Ref.fresh(rc, Nil);
        let outcome = DbError.runWithFailure(() -> Retry.withRetryWith(Retry.defaultPolicy(), recordWait(log), () -> 1.0, () -> TransientDbErr.timeout(500)));
        (outcome, Ref.get(log) |> List.reverse)
    };
    Assert.assertEq(expected = (Err(DbError.Failure.Permanent(DbError.DbErrorKind.RetryExhausted(DbError.TransientKind.Timeout(500), 3))), List#{100, 200}), (result, waits))

/// jitter は失敗のたびに呼ばれ、その回の待ちに掛かる（0.5 なら上限の半分）。
@Test
def testRetryWithJitterIsAppliedEachTime(): Unit \ Assert =
    let waits: List[Int32] = region rc {
        let log = Ref.fresh(rc, Nil);
        discard DbError.runWithFailure(() -> Retry.withRetryWith({ attempts = 4, baseMs = 100, maxMs = 250 }, recordWait(log), () -> 0.5, () -> TransientDbErr.deadlock()));
        Ref.get(log) |> List.reverse
    };
    Assert.assertEq(expected = List#{50, 100, 125}, waits)
