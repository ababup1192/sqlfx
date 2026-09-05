mod SqlState {

    use DbError.DbErrorKind

    ///
    /// PostgreSQL の sqlstate とメッセージを、どの op に翻訳するかの enum に落とす。純粋なので DB 無しでテストする。
    ///
    /// sqlstate の一覧: https://www.postgresql.org/docs/current/errcodes-appendix.html
    ///
    pub def classify(sqlState: String, message: String): DbErrorKind =
        if (sqlState == "23505")
            DbErrorKind.Conflict(constraintName(message))
        else if (sqlState == "23503")
            DbErrorKind.InvalidRef(constraintName(message))
        else if (sqlState == "40001" or sqlState == "40P01")
            DbErrorKind.Deadlock
        else if (sqlState == "57014")
            DbErrorKind.Timeout(0)
        else if (String.startsWith(prefix = "08", sqlState))
            DbErrorKind.ConnectionLost(message)
        else if (sqlState == "42P01" or sqlState == "42703" or sqlState == "42883" or sqlState == "42804")
            DbErrorKind.SchemaMismatch(message)
        else
            DbErrorKind.Corrupt("${sqlState}: ${message}")

    ///
    /// PG のエラーメッセージから制約名を取り出す。制約名は最後の引用符の中に来る。
    /// `duplicate key value violates unique constraint "users_email_key"` → `users_email_key`、
    /// `insert or update on table "posts" violates foreign key constraint "posts_user_id_fkey"` → `posts_user_id_fkey`。
    /// 引用符が無ければメッセージ全体を返す（情報を捨てない）。
    ///
    /// WhyNot: pgjdbc の `ServerErrorMessage.getConstraint()` を使わないのは、null を返すことがあり
    /// Java の null を Flix 側で扱う面倒を JDBC ハンドラの外へ広げたくないから。メッセージの形は PG が安定させている。
    ///
    pub def constraintName(message: String): String =
        String.splitOn(substr = "\"", message)
            |> List.zipWithIndex
            |> List.filterMap(match (index, part) -> if (Int32.remainder(index, 2) == 1) Some(part) else None)
            |> List.last
            |> Option.getWithDefault(message)

}
