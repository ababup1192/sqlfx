pub mod Sqlfx.DbErr {

    use Sqlfx.DbError

    use Sqlfx.DbError.DbErrorKind

    ///
    /// unique 制約違反（制約名）。
    ///
    pub def uniqueViolation(constraint: String): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.UniqueViolation(constraint))

    ///
    /// 外部キー制約違反（制約名）。
    ///
    pub def foreignKeyViolation(constraint: String): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.ForeignKeyViolation(constraint))

    ///
    /// CHECK 制約違反（制約名）。
    ///
    pub def checkViolation(constraint: String): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.CheckViolation(constraint))

    ///
    /// NOT NULL 違反（列名）。生成された関数の引数の型が守るので、生 SQL か UPDATE で NULL を書いたときに出る。
    ///
    pub def notNullViolation(column: String): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.NotNullViolation(column))

    ///
    /// テーブルや列が無い = デプロイミス。
    ///
    pub def schemaMismatch(detail: String): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.SchemaMismatch(detail))

    ///
    /// 結果セットの列が期待した型で読めない。
    ///
    pub def decodeError(column: String, detail: String): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.DecodeError(column, detail))

    ///
    /// withRetry が枯渇した。last は最後の失敗、attempts は呼んだ回数。
    ///
    pub def retryExhausted(last: DbError.TransientKind, attempts: Int32): a \ DbErr =
        Sqlfx.DbErr.raise(DbErrorKind.RetryExhausted(last, attempts))

    ///
    /// 業務の都合で Tx を巻き戻したい。DB の失敗ではない。値で受けたいなら `Pool.withLazyTxResult`。
    ///
    pub def rollback(): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.Rollback)

    ///
    /// 上のどれにも当てはまらない DB エラー（sqlstate とメッセージ）。
    ///
    pub def other(detail: String): a \ DbErr = Sqlfx.DbErr.raise(DbErrorKind.Other(detail))

    ///
    /// DbErr だけを Result に落とす。Transient は上へ流したまま、DbErr だけ値にしたいときに使う。
    /// 人が読む 1 行は `DbError.describe(kind)`。
    /// thunk の中で投げた JVM の例外は `run` を抜けてから投げ直す（`Db.rethrowing`）。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[DbErrorKind, a] \ ef - DbErr =
        let outcome = run {
                Ok(Sqlfx.Db.catchAll(thunk))
            } with handler DbErr {
                def raise(kind, _resume) = Err(kind)
            };
        Result.map(Sqlfx.Db.rethrowing, outcome)

}
