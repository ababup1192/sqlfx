mod Tx {

    import java.sql.Connection
    import java.sql.SQLException

    ///
    /// BEGIN してから thunk を同じ接続で走らせ、正常なら COMMIT、Transient / DbErr のどちらかが飛べば ROLLBACK して再送出。
    /// thunk の SqlRead / SqlWrite はこの接続で実行する（`Jdbc.runWithConnection` を内側に被せる）。
    ///
    /// v0 ではネストを扱わない。thunk の中でまた `withTx` を同じ接続で呼ぶと内側の COMMIT で外側も確定する。
    /// セーブポイントにするか型で禁止するかは v2 で決める（design.md §4.3）。
    ///
    pub def withTx(conn: Connection, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        begin(conn);
        let value = run {
            Jdbc.runWithConnection(conn, thunk)
        } with handler TransientDbErr {
            def deadlock(_resume) = { rollback(conn); TransientDbErr.deadlock() }
            def timeout(ms, _resume) = { rollback(conn); TransientDbErr.timeout(ms) }
            def connectionLost(msg, _resume) = { rollback(conn); TransientDbErr.connectionLost(msg) }
        } with handler DbErr {
            def uniqueViolation(constraint, _resume) = { rollback(conn); DbErr.uniqueViolation(constraint) }
            def foreignKeyViolation(constraint, _resume) = { rollback(conn); DbErr.foreignKeyViolation(constraint) }
            def schemaMismatch(detail, _resume) = { rollback(conn); DbErr.schemaMismatch(detail) }
            def decodeError(column, detail, _resume) = { rollback(conn); DbErr.decodeError(column, detail) }
            def retryExhausted(last, _resume) = { rollback(conn); DbErr.retryExhausted(last) }
            def corrupt(detail, _resume) = { rollback(conn); DbErr.corrupt(detail) }
        };
        commit(conn);
        value

    ///
    /// autocommit を切って Tx を始める。
    ///
    def begin(conn: Connection): Unit \ {IO, TransientDbErr, DbErr} =
        try {
            conn.setAutoCommit(false)
        } catch {
            case e: SQLException => Jdbc.raiseSqlException(e)
        }

    ///
    /// COMMIT して autocommit に戻す。COMMIT 自体の失敗（直列化失敗など）も翻訳する。
    ///
    def commit(conn: Connection): Unit \ {IO, TransientDbErr, DbErr} =
        try {
            conn.commit();
            conn.setAutoCommit(true)
        } catch {
            case e: SQLException => Jdbc.raiseSqlException(e)
        }

    ///
    /// ROLLBACK して autocommit に戻す。ROLLBACK の失敗は握りつぶす（元のエラーをそのまま再送出したいので）。
    ///
    def rollback(conn: Connection): Unit \ IO =
        try {
            conn.rollback();
            conn.setAutoCommit(true)
        } catch {
            case _: SQLException => ()
        }

}
