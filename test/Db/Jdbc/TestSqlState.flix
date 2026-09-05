use DbError.DbErrorKind

// SqlState: sqlstate → DbErrorKind の翻訳表。

/// unique 違反と FK 違反は制約名付きの Domain。
@Test
def testClassifyDomain(): Unit \ Assert =
    Assert.assertEq(
        expected = (DbErrorKind.Conflict("users_email_key"), DbErrorKind.InvalidRef("posts_user_id_fkey")),
        (
            SqlState.classify("23505", "duplicate key value violates unique constraint \"users_email_key\""),
            SqlState.classify("23503", "insert or update on table \"posts\" violates foreign key constraint \"posts_user_id_fkey\"")
        ))

/// デッドロック・直列化失敗・statement_timeout・接続断は Transient。
@Test
def testClassifyTransient(): Unit \ Assert =
    Assert.assertEq(
        expected = (DbErrorKind.Deadlock, DbErrorKind.Deadlock, DbErrorKind.Timeout(0), DbErrorKind.ConnectionLost("terminating connection")),
        (
            SqlState.classify("40P01", "deadlock detected"),
            SqlState.classify("40001", "could not serialize access"),
            SqlState.classify("57014", "canceling statement due to statement timeout"),
            SqlState.classify("08006", "terminating connection")
        ))

/// テーブルや列が無い・型が合わないは SchemaMismatch。知らない sqlstate は Corrupt にコードごと残す。
@Test
def testClassifyFatal(): Unit \ Assert =
    Assert.assertEq(
        expected = (DbErrorKind.SchemaMismatch("relation \"userz\" does not exist"), DbErrorKind.Corrupt("XX000: internal error")),
        (
            SqlState.classify("42P01", "relation \"userz\" does not exist"),
            SqlState.classify("XX000", "internal error")
        ))

/// 制約名は最初の引用符の中。引用符が無ければメッセージ全体。
@Test
def testConstraintName(): Unit \ Assert =
    Assert.assertEq(
        expected = ("users_email_key", "no quotes here"),
        (SqlState.constraintName("violates unique constraint \"users_email_key\""), SqlState.constraintName("no quotes here")))
