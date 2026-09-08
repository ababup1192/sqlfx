use DbError.DbErrorKind
use DbError.TransientKind

// SqlState: sqlstate → DbErrorKind の翻訳表。

/// unique 違反と FK 違反は制約名付きの Domain。
@Test
def testClassifyDomain(): Unit \ Assert =
    Assert.assertEq(
        expected = (DbErrorKind.UniqueViolation("users_email_key"), DbErrorKind.ForeignKeyViolation("posts_user_id_fkey")),
        (
            SqlState.classify({ sqlState = "23505", message = "duplicate key value violates unique constraint \"users_email_key\"" }),
            SqlState.classify({ sqlState = "23503", message = "insert or update on table \"posts\" violates foreign key constraint \"posts_user_id_fkey\"" })
        ))

/// デッドロック・直列化失敗・statement_timeout・lock_timeout・接続断・admin_shutdown（DB の再起動）は Transient。
///
///   40P01 → deadlock          40001 → deadlock
///   57014 → timeout 0         55P03 → timeout 0
///   08006 → connectionLost    57P01 → connectionLost
@Test
def testClassifyTransient(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{
            DbErrorKind.Transient(TransientKind.Deadlock),
            DbErrorKind.Transient(TransientKind.Deadlock),
            DbErrorKind.Transient(TransientKind.Timeout(0)),
            DbErrorKind.Transient(TransientKind.Timeout(0)),
            DbErrorKind.Transient(TransientKind.ConnectionLost("terminating connection")),
            DbErrorKind.Transient(TransientKind.ConnectionLost("terminating connection due to administrator command"))
        },
        List#{
            SqlState.classify({ sqlState = "40P01", message = "deadlock detected" }),
            SqlState.classify({ sqlState = "40001", message = "could not serialize access" }),
            SqlState.classify({ sqlState = "57014", message = "canceling statement due to statement timeout" }),
            SqlState.classify({ sqlState = "55P03", message = "canceling statement due to lock timeout" }),
            SqlState.classify({ sqlState = "08006", message = "terminating connection" }),
            SqlState.classify({ sqlState = "57P01", message = "terminating connection due to administrator command" })
        })

/// テーブルや列が無い・型が合わないは SchemaMismatch。知らない sqlstate は Corrupt にコードごと残す。
@Test
def testClassifyFatal(): Unit \ Assert =
    Assert.assertEq(
        expected = (DbErrorKind.SchemaMismatch("relation \"userz\" does not exist"), DbErrorKind.Other("XX000: internal error")),
        (
            SqlState.classify({ sqlState = "42P01", message = "relation \"userz\" does not exist" }),
            SqlState.classify({ sqlState = "XX000", message = "internal error" })
        ))

/// 制約名は最後の引用符の中。引用符が無ければメッセージ全体。
@Test
def testConstraintName(): Unit \ Assert =
    Assert.assertEq(
        expected = ("users_email_key", "no quotes here"),
        (SqlState.constraintName("violates unique constraint \"users_email_key\""), SqlState.constraintName("no quotes here")))

/// サーバが制約名を返していればメッセージは見ない（日本語ロケールでは最後の引用符がテーブル名になる）。
@Test
def testClassifyPrefersServerConstraint(): Unit \ Assert =
    Assert.assertEq(
        expected = DbErrorKind.ForeignKeyViolation("posts_user_id_fkey"),
        SqlState.classifyWith({ sqlState = "23503", message = "テーブル\"posts\"の挿入または更新は外部キー制約\"posts_user_id_fkey\"に違反しています キーはテーブル\"users\"に存在しません", constraint = Some("posts_user_id_fkey"), column = None }))

/// CHECK 違反は制約名付き、NOT NULL 違反は列名付き。列名はメッセージの最後の引用符がテーブル名なので、サーバが返した列名を使う。
@Test
def testClassifyCheckAndNotNull(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{DbErrorKind.CheckViolation("users_name_length"), DbErrorKind.NotNullViolation("email")},
        List#{
            SqlState.classifyWith({ sqlState = "23514", message = "new row for relation \"users\" violates check constraint \"users_name_length\"", constraint = Some("users_name_length"), column = None }),
            SqlState.classifyWith({ sqlState = "23502", message = "null value in column \"email\" of relation \"users\" violates not-null constraint", constraint = None, column = Some("email") })
        })

/// pgjdbc が列名を返さないとき（包み直された SQLException など）は、メッセージの最初の引用符を列名にする。最後の引用符はテーブル名。
@Test
def testNotNullFallsBackToFirstQuoted(): Unit \ Assert =
    Assert.assertEq(
        expected = DbErrorKind.NotNullViolation("email"),
        SqlState.classifyWith({ sqlState = "23502", message = "null value in column \"email\" of relation \"users\" violates not-null constraint", constraint = None, column = None }))
