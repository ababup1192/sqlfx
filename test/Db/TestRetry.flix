// Retry: Transient を捕まえて thunk を呼び直す（DB 無し）。

/// 2 回 Transient で失敗して 3 回目で成功する thunk は、attempts = 3 なら成功する。
///
///   attempt 1: deadlock
///   attempt 2: deadlock
///   attempt 3: Ok
@Test
def testRetrySucceedsWithinAttempts(): Unit \ Assert =
    let (result, calls): (Result[DbError.DbFailure, String], Int32) = region rc {
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
    Assert.assertEq(expected = Err(DbError.DbFailure.Permanent("retryExhausted timeout 500 after 2 attempts")), result |> Result.map(_ -> ()))

/// DbErr は再試行しない（1 回で外へ出る）。
@Test
def testRetryDoesNotRetryDbErr(): Unit \ Assert =
    let (result, calls): (Result[DbError.DbFailure, Unit], Int32) = region rc {
        let counter = Ref.fresh(rc, 0);
        let thunk = () -> {
            Ref.put(Ref.get(counter) + 1, counter);
            DbErr.uniqueViolation("users_email_key")
        };
        (DbError.runWithFailure(() -> Retry.withRetry(3, thunk)), Ref.get(counter))
    };
    Assert.assertEq(expected = (Err(DbError.DbFailure.Permanent("uniqueViolation users_email_key")), 1), (result |> Result.map(_ -> ()), calls))

/// attempts が 1 未満でも 1 回は走り、枯渇のメッセージも 1 回と言う。
@Test
def testRetryAttemptsBelowOneRunsOnce(): Unit \ Assert =
    let result: Result[DbError.DbFailure, Unit] = DbError.runWithFailure(() -> Retry.withRetry(0, () -> TransientDbErr.deadlock()));
    Assert.assertEq(expected = Err(DbError.DbFailure.Permanent("retryExhausted deadlock after 1 attempts")), result)
