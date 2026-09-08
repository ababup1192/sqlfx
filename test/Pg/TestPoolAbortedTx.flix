use DbError.DbErrorKind
use DbError.Failure

// ---- Tx の中で Db.attempt ----

/// Tx の中の SQL の失敗を Db.attempt で値にすると PG の Tx は aborted のままで、次の SQL は 25P02 で失敗する。
/// そのまま thunk が値を返しても PG は COMMIT を ROLLBACK にするので、withLazyTx は Ok で返してはいけない（書いた物が黙って消える）。
///
///   BEGIN  INSERT a  attempt(INSERT a 重複) → Err  INSERT b → 25P02（Other）
///   BEGIN  INSERT c  attempt(INSERT c 重複) → Err  "done" を返す → ROLLBACK して DbErr.rollback … 行は残らない
@Test
def testPoolLazyTxAttemptInsideAbortedTx(): Unit \ {Assert, IO} =
    let pool = leakPool();
    resetLeakTable(pool);
    let continued: Result[Bool, Unit] = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        insertLeakRow("a");
        discard Db.attempt(() -> insertLeakRow("a"));
        insertLeakRow("b")
    })))
        |> Result.mapErr(failure -> String.startsWith(prefix = "other 25P02", DbError.describeFailure(failure)));
    let finished: Result[Failure, String] = RawSql.runWithAllow(() -> DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> {
        insertLeakRow("c");
        discard Db.attempt(() -> insertLeakRow("c"));
        "done"
    })));
    let rows = countLeakRows(pool);
    let (active, next) = probe(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (Err(true), Err(Failure.Permanent(DbErrorKind.Rollback)), Ok(0), 0, Ok(1)), (continued, finished, rows, active, next))
