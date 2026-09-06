mod Tx {

    import java.sql.Connection
    import java.sql.SQLException

    ///
    /// BEGIN してから thunk を同じ接続で走らせ、正常なら COMMIT、Transient / DbErr のどちらかが飛べば ROLLBACK して再送出。
    /// thunk の SqlRead / SqlWrite はこの接続で実行する（内側で `Jdbc.runWithConnection` を被せるので、外側で被せ直す必要は無い）。
    ///
    /// v0 ではネストを扱わない。thunk の中でまた `withTx` を同じ接続で呼ぶと内側の COMMIT で外側も確定する。
    /// セーブポイントにするか型で禁止するかは v2 で決める（design.md §4.3）。
    ///
    pub def withTx(conn: Connection, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        begin(conn);
        match DbError.runWithKind(() -> Jdbc.runWithConnection(conn, thunk)) {
            case Ok(value) => { commit(conn); value }
            case Err(kind) => { rollback(conn); DbError.raise(kind) }
        }

    ///
    /// autocommit を切って Tx を始める。`Pool.withLazyTx` のように Tx の形を自分で組む所から呼ぶ。
    ///
    pub def begin(conn: Connection): Unit \ {IO, TransientDbErr, DbErr} =
        try {
            conn.setAutoCommit(false)
        } catch {
            case e: SQLException => Jdbc.raiseSqlException(e)
        }

    ///
    /// COMMIT して autocommit に戻す。COMMIT 自体の失敗（直列化失敗など）も翻訳する。
    /// 失敗したら ROLLBACK して autocommit に戻してから投げる。戻さないと、次の文が誰も COMMIT しない Tx に入る。
    ///
    pub def commit(conn: Connection): Unit \ {IO, TransientDbErr, DbErr} =
        try {
            conn.commit();
            conn.setAutoCommit(true)
        } catch {
            case e: SQLException => { rollback(conn); Jdbc.raiseSqlException(e) }
        }

    ///
    /// ROLLBACK して autocommit に戻す。ROLLBACK の失敗は握りつぶす（元のエラーをそのまま再送出したいので）。
    ///
    pub def rollback(conn: Connection): Unit \ IO =
        try {
            conn.rollback();
            conn.setAutoCommit(true)
        } catch {
            case _: SQLException => ()
        }

}
