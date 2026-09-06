use DbError.DbErrorKind

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

/// デッドロック・直列化失敗・statement_timeout・接続断は Transient。
@Test
def testClassifyTransient(): Unit \ Assert =
    Assert.assertEq(
        expected = (DbErrorKind.Deadlock, DbErrorKind.Deadlock, DbErrorKind.Timeout(0), DbErrorKind.ConnectionLost("terminating connection")),
        (
            SqlState.classify({ sqlState = "40P01", message = "deadlock detected" }),
            SqlState.classify({ sqlState = "40001", message = "could not serialize access" }),
            SqlState.classify({ sqlState = "57014", message = "canceling statement due to statement timeout" }),
            SqlState.classify({ sqlState = "08006", message = "terminating connection" })
        ))

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
        SqlState.classifyWith({ sqlState = "23503", message = "テーブル\"posts\"の挿入または更新は外部キー制約\"posts_user_id_fkey\"に違反しています キーはテーブル\"users\"に存在しません", constraint = Some("posts_user_id_fkey") }))
