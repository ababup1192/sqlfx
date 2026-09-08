mod SqlState {

    use DbError.DbErrorKind
    use DbError.TransientKind

    ///
    /// PostgreSQL の sqlstate とメッセージを、どの op に翻訳するかの enum に落とす。純粋なので DB 無しでテストする。
    ///
    /// sqlstate の一覧: https://www.postgresql.org/docs/current/errcodes-appendix.html
    ///
    pub def classify(error: { sqlState = String, message = String }): DbErrorKind =
        classifyWith({ sqlState = error#sqlState, message = error#message, constraint = None, column = None })

    ///
    /// サーバが制約名や列名を別枠で返しているとき（pgjdbc の ServerErrorMessage.getConstraint / getColumn）はそれを優先する。
    /// 無ければメッセージから取り出す。
    ///
    /// WhyNot: メッセージの解析だけに頼らないのは、PG のメッセージがロケールで変わり、日本語では
    /// 制約名の後ろにテーブル名の引用が続いて「最後の引用符」が制約名にならないから。
    ///
    pub def classifyWith(error: { sqlState = String, message = String, constraint = Option[String], column = Option[String] }): DbErrorKind =
        let sqlState = error#sqlState;
        let message = error#message;
        let constraint = error#constraint;
        if (sqlState == "23505")
            DbErrorKind.UniqueViolation(Option.getWithDefault(constraintName(message), constraint))
        else if (sqlState == "23503")
            DbErrorKind.ForeignKeyViolation(Option.getWithDefault(constraintName(message), constraint))
        else if (sqlState == "23514")
            DbErrorKind.CheckViolation(Option.getWithDefault(constraintName(message), constraint))
        else if (sqlState == "23502")
            DbErrorKind.NotNullViolation(Option.getWithDefault(columnName(message), error#column))
        else if (sqlState == "40001" or sqlState == "40P01")
            DbErrorKind.Transient(TransientKind.Deadlock)
        else if (sqlState == "57014")
            DbErrorKind.Transient(TransientKind.Timeout(0))
        else if (String.startsWith(prefix = "08", sqlState))
            DbErrorKind.Transient(TransientKind.ConnectionLost(message))
        else if (sqlState == "42P01" or sqlState == "42703" or sqlState == "42883" or sqlState == "42804")
            DbErrorKind.SchemaMismatch(message)
        else
            DbErrorKind.Other("${sqlState}: ${message}")

    ///
    /// PG のエラーメッセージから制約名を取り出す。制約名は最後の引用符の中に来る。
    /// `duplicate key value violates unique constraint "users_email_key"` → `users_email_key`、
    /// `insert or update on table "posts" violates foreign key constraint "posts_user_id_fkey"` → `posts_user_id_fkey`。
    /// 引用符が無ければメッセージ全体を返す（情報を捨てない）。
    ///
    /// pgjdbc が制約名を返さなかったときの保険。
    ///
    pub def constraintName(message: String): String =
        quoted(message) |> List.last |> Option.getWithDefault(message)

    ///
    /// NOT NULL 違反のメッセージから列名を取り出す。列名は最初の引用符の中に来る。
    /// `null value in column "email" of relation "users" violates not-null constraint` → `email`（最後の引用符はテーブル名）。
    ///
    /// pgjdbc が列名を返さなかったときの保険。
    ///
    pub def columnName(message: String): String =
        quoted(message) |> List.head |> Option.getWithDefault(message)

    ///
    /// 引用符で囲まれた部分を順に。
    ///
    def quoted(message: String): List[String] =
        String.splitOn(substr = "\"", message)
            |> List.zipWithIndex
            |> List.filterMap(match (index, part) -> if (Int32.remainder(index, 2) == 1) Some(part) else None)

}
