///
/// JDBC ハンドラ。SqlRead / SqlWrite を java.sql に落とし、SQLException を 3 分類に翻訳する。
///
mod Jdbc {

    import java.sql.Connection
    import java.sql.PreparedStatement
    import java.sql.ResultSet
    import java.sql.SQLException
    import org.postgresql.util.PSQLException
    import org.postgresql.util.ServerErrorMessage
    import java.util.Properties
    import org.postgresql.Driver

    use SqlValue.SqlValue
    use Row.Row

    ///
    /// 接続の設定。
    ///
    /// - `url`: `jdbc:postgresql://host:port/db`
    /// - `user` / `password`: 認証
    ///
    pub type alias ConnectionConfig = { url = String, user = String, password = String }

    ///
    /// 1 本の接続を開く。開けなければ TransientDbErr.connectionLost。
    ///
    /// WhyNot: `DriverManager.getConnection` を使わないのは、Flix の Maven クラスローダでは
    /// ドライバの自動登録が効かないから（docs/spikes.md (c)）。`Driver` を直接 new する。
    ///
    pub def connect(config: ConnectionConfig): Connection \ {IO, TransientDbErr} =
        try {
            let props = new Properties();
            props.setProperty("user", config#user);
            props.setProperty("password", config#password);
            let driver = new Driver();
            driver.connect(config#url, props)
        } catch {
            case e: SQLException =>
                let msg: String = e.getMessage();
                TransientDbErr.connectionLost(msg)
        }

    ///
    /// 接続を閉じる。閉じるときの失敗は握りつぶす（もう使わない接続なので）。
    ///
    pub def close(conn: Connection): Unit \ IO =
        try {
            conn.close()
        } catch {
            case _: SQLException => ()
        }

    ///
    /// 1 本の接続で fetch / execute を実行する。結果は即時 materialize する。
    /// 失敗は値（DbErrorKind）で継続に渡し、呼び出し側の `Sql.*` が op にする。継続は必ず 1 回呼ぶ。
    ///
    pub def runWithConnection(conn: Connection, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + IO =
        run {
            thunk()
        } with handler SqlRead {
            def fetch(sql, params, resume) = resume(DbError.runWithKind(() -> fetchRows(conn, sql, params)))
        } with handler SqlWrite {
            def execute(sql, params, resume) = resume(DbError.runWithKind(() -> executeStatement(conn, sql, params)))
            def executeReturning(sql, params, resume) = resume(DbError.runWithKind(() -> fetchRows(conn, sql, params)))
        }

    ///
    /// 接続を開いて thunk を走らせ、成功でも失敗でも必ず閉じる。失敗はそのまま再送出する。
    /// 「開く → runWithConnection → 閉じる」を毎回書かないための入口。Tx が要るなら thunk の中で `Tx.withTx` を呼ぶ。
    ///
    pub def withConnection(config: ConnectionConfig, thunk: Connection -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        let conn = connect(config);
        let outcome = DbError.runWithKind(() -> runWithConnection(conn, () -> thunk(conn)));
        close(conn);
        match outcome {
            case Ok(value) => value
            case Err(kind) => DbError.raise(kind)
        }

    ///
    /// SELECT を発行して全行読む。
    ///
    pub def fetchRows(conn: Connection, sql: String, params: List[SqlValue]): List[Row] \ {IO, TransientDbErr, DbErr} =
        let (jdbcSql, ordered) = rewriteOrFail(sql, params);
        let statement = prepare(conn, jdbcSql);
        try {
            JdbcConvert.bindParams(conn, statement, ordered);
            let resultSet: ResultSet = statement.executeQuery();
            let rows = JdbcConvert.materialize(resultSet);
            resultSet.close();
            statement.close();
            rows
        } catch {
            case e: SQLException => { closeQuietly(statement); raiseSqlException(e) }
        }

    ///
    /// INSERT / UPDATE / DELETE を発行して影響行数を返す。
    ///
    pub def executeStatement(conn: Connection, sql: String, params: List[SqlValue]): Int32 \ {IO, TransientDbErr, DbErr} =
        let (jdbcSql, ordered) = rewriteOrFail(sql, params);
        let statement = prepare(conn, jdbcSql);
        try {
            JdbcConvert.bindParams(conn, statement, ordered);
            let affected: Int32 = statement.executeUpdate();
            statement.close();
            affected
        } catch {
            case e: SQLException => { closeQuietly(statement); raiseSqlException(e) }
        }

    ///
    /// PreparedStatement を作る。ここで失敗したら閉じる物は無い。
    ///
    def prepare(conn: Connection, jdbcSql: String): PreparedStatement \ {IO, TransientDbErr, DbErr} =
        try {
            conn.prepareStatement(jdbcSql)
        } catch {
            case e: SQLException => raiseSqlException(e)
        }

    ///
    /// 失敗した文を閉じる。閉じるときの失敗は元のエラーを優先して握りつぶす。
    ///
    def closeQuietly(statement: PreparedStatement): Unit \ IO =
        try {
            statement.close()
        } catch {
            case _: SQLException => ()
        }

    ///
    /// `$n` を `?` に書き換える。params に無い `$n` を参照していたら DbErr.other（SQL の書き間違い）。
    ///
    def rewriteOrFail(sql: String, params: List[SqlValue]): (String, List[SqlValue]) \ DbErr =
        match JdbcConvert.rewritePlaceholders(sql, params) {
            case Some(rewritten) => rewritten
            case None => DbErr.other("placeholder out of range (${List.length(params)} params): ${sql}")
        }

    ///
    /// SQLException を sqlstate で 3 分類に翻訳して投げる。sqlstate が無い（ドライバ内部の失敗）ときは空文字で Corrupt へ。
    ///
    pub def raiseSqlException(e: SQLException): a \ {IO, TransientDbErr, DbErr} =
        let state: String = e.getSQLState();
        let message: String = e.getMessage();
        let safeState = if (Object.isNull(state)) "" else state;
        let safeMessage = if (Object.isNull(message)) "" else message;
        DbError.raise(SqlState.classifyWith({ sqlState = safeState, message = safeMessage, constraint = serverConstraint(e) }))

    ///
    /// pgjdbc の例外ならサーバが返した制約名を取り出す。それ以外の SQLException や、制約の無いエラーは None。
    ///
    def serverConstraint(e: SQLException): Option[String] \ IO =
        let className: String = e.getClass().getName();
        if (className != "org.postgresql.util.PSQLException")
            None
        else {
            let psql: PSQLException = unchecked_cast(e as PSQLException);
            let server: ServerErrorMessage = psql.getServerErrorMessage();
            if (Object.isNull(server)) None
            else {
                let constraint: String = server.getConstraint();
                if (Object.isNull(constraint)) None else Some(constraint)
            }
        }

}
