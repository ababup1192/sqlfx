import java.lang.OutOfMemoryError
import java.lang.RuntimeException
import java.lang.StackOverflowError

use DbError.DbErrorKind
use DbError.TransientKind

// DbError: 2 つのエフェクトの op は 1 本（raise）で、種類は DbErrorKind の値。
// 値 → op → 値の往復と、1 腕だけの手書きハンドラを確かめる。

/// 全ての kind。case を足したらここにも足す（往復とハンドラのテストが自動で広がる）。
def allKinds(): List[DbErrorKind] = List#{
    DbErrorKind.Transient(TransientKind.Deadlock),
    DbErrorKind.Transient(TransientKind.Timeout(500)),
    DbErrorKind.Transient(TransientKind.ConnectionLost("terminating connection")),
    DbErrorKind.UniqueViolation("users_email_key"),
    DbErrorKind.ForeignKeyViolation("posts_user_id_fkey"),
    DbErrorKind.CheckViolation("users_name_length"),
    DbErrorKind.NotNullViolation("email"),
    DbErrorKind.SchemaMismatch("relation \"userz\" does not exist"),
    DbErrorKind.DecodeError("id", "column 'id' is Int64, expected Int32"),
    DbErrorKind.RetryExhausted(TransientKind.Timeout(500), 3),
    DbErrorKind.Rollback,
    DbErrorKind.Other("XX000: internal error")
}

/// raise した kind は runWithKind でそのまま値に戻る（op が 1 本でも種類は失われない）。
@Test
def testKindRoundTrip(): Unit \ Assert =
    let roundTrip = kind -> DbError.runWithKind(() -> DbError.raise(kind)) |> Result.map(_ -> ());
    Assert.assertEq(expected = allKinds() |> List.map(Err), allKinds() |> List.map(roundTrip))

/// 一時障害だけが isTransient。
@Test
def testIsTransient(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{true, true, true, false, false, false, false, false, false, false, false, false},
        allKinds() |> List.map(DbError.isTransient))

/// 一時障害は TransientDbErr へ、それ以外は DbErr へ振り分けられる（TransientDbErr だけ受けると、残りは上へ流れる）。
@Test
def testRaiseRoutesToTheRightEffect(): Unit \ Assert =
    let caughtByTransient = kind ->
        DbError.runWithKind(() -> TransientDbErr.runWithResult(() -> DbError.raise(kind)))
            |> Result.map(Result.isOk);
    Assert.assertEq(
        expected = allKinds() |> List.map(kind -> if (DbError.isTransient(kind)) Ok(false) else Err(kind)),
        allKinds() |> List.map(caughtByTransient))

/// 手書きのハンドラは 1 腕で済む。kind を足してもこのハンドラは壊れない。
@Test
def testHandwrittenHandlerHasOneArm(): Unit \ Assert =
    let caught = run {
        DbErr.uniqueViolation("users_email_key")
    } with handler DbErr {
        def raise(kind, _resume) = kind
    };
    Assert.assertEq(expected = DbErrorKind.UniqueViolation("users_email_key"), caught)

/// 人が読む 1 行。
@Test
def testDescribeKind(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{
            "deadlock",
            "timeout 500",
            "connectionLost terminating connection",
            "uniqueViolation users_email_key",
            "foreignKeyViolation posts_user_id_fkey",
            "checkViolation users_name_length",
            "notNullViolation email",
            "schemaMismatch relation \"userz\" does not exist",
            "id: column 'id' is Int64, expected Int32",
            "retryExhausted timeout 500 after 3 attempts",
            "rollback",
            "other XX000: internal error"
        },
        allKinds() |> List.map(DbError.describe))

/// 制約名を持つのは UNIQUE / FK / CHECK だけ（notNullViolation は列名なので None）。
@Test
def testKindConstraintName(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{
            None, None, None,
            Some("users_email_key"), Some("posts_user_id_fkey"), Some("users_name_length"),
            None, None, None, None, None, None
        },
        allKinds() |> List.map(DbError.constraintName))

/// 失敗は 2 分類の enum。一時障害は Transient、それ以外は Permanent に kind をそのまま持つ。
@Test
def testRunWithFailureSplitsInTwo(): Unit \ Assert =
    let toFailure = kind -> DbError.runWithFailure(() -> DbError.raise(kind)) |> Result.map(_ -> ());
    Assert.assertEq(
        expected = allKinds() |> List.map(kind -> match DbError.transientOf(kind) {
            case Some(transient) => Err(DbError.Failure.Transient(transient))
            case None            => Err(DbError.Failure.Permanent(kind))
        }),
        allKinds() |> List.map(toFailure))

/// 人が読む 1 行は describeFailure（describe と同じ文言）。
@Test
def testDescribeFailure(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{"deadlock", "uniqueViolation users_email_key"},
        List#{
            DbError.describeFailure(DbError.Failure.Transient(TransientKind.Deadlock)),
            DbError.describeFailure(DbError.Failure.Permanent(DbErrorKind.UniqueViolation("users_email_key")))
        })

/// Db.attempt は DB の失敗を値にする。成功はそのまま Ok。
@Test
def testAttempt(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{Ok(1), Err(DbError.Failure.Permanent(DbErrorKind.UniqueViolation("users_email_key")))},
        List#{
            Db.attempt(() -> 1),
            Db.attempt(() -> DbErr.uniqueViolation("users_email_key"))
        })

/// DbErr.runWithResult は kind をそのまま返す（TransientDbErr.runWithResult が TransientKind を返すのと同じ形）。
@Test
def testDbErrRunWithResultKeepsKind(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{Ok(1), Err(DbErrorKind.UniqueViolation("users_email_key"))},
        List#{
            DbErr.runWithResult(() -> 1),
            DbErr.runWithResult(() -> DbErr.uniqueViolation("users_email_key"))
        })

/// Db.guard は JVM の例外を DbErr の Other にする。文言は message、無ければ class 名。StackOverflowError も Other。値はそのまま通る。
@Test
def testGuardTurnsExceptionsIntoOther(): Unit \ {Assert, IO} =
    let thunks: List[Unit -> Int32 \ IO] = List#{
        () -> 1,
        () -> throw new RuntimeException("boom"),
        () -> throw new RuntimeException(),
        () -> throw new StackOverflowError("deep")
    };
    Assert.assertEq(
        expected = List#{
            Ok(1),
            Err(DbError.Failure.Permanent(DbErrorKind.Other("boom"))),
            Err(DbError.Failure.Permanent(DbErrorKind.Other("java.lang.RuntimeException"))),
            Err(DbError.Failure.Permanent(DbErrorKind.Other("deep")))
        },
        thunks |> List.map(thunk -> Db.attempt(() -> Db.guard(thunk))))

/// VirtualMachineError（OutOfMemoryError）は Db.guard を素通りして再送出される。
@Test
def testGuardRethrowsFatal(): Unit \ {Assert, IO} =
    let escaped = DbErr.runWithResult(() ->
        try {
            Db.guard(() -> throw new OutOfMemoryError("fake"))
        } catch {
            case _: OutOfMemoryError => true
        });
    Assert.assertEq(expected = Ok(true), escaped)
