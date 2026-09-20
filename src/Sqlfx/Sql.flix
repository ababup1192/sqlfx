pub mod Sqlfx.Sql {

    use Sqlfx.DbErr
    use Sqlfx.DbError
    use Sqlfx.DbRead
    use Sqlfx.DbWrite
    use Sqlfx.Decoder
    use Sqlfx.RawSql
    use Sqlfx.Row
    use Sqlfx.SqlRead
    use Sqlfx.SqlValue
    use Sqlfx.SqlWrite
    use Sqlfx.TransientDbErr

    use Sqlfx.SqlValue.SqlValue
    use Sqlfx.Row.Row
    use Sqlfx.Decoder.Decoder

    ///
    /// SELECT を発行して全行返す。利用者は op を直接呼ばず、これを使う。
    /// 生の SQL 文字列を受けるので `RawSql` が付く。生 SQL に依存する関数が型シグネチャから列挙できる。
    /// 境界（main / テスト）と、生成器が検査した SQL を持つ生成コードが `RawSql.runWithAllow` で許可する。
    ///
    pub def fetch(sql: String, params: List[SqlValue]): List[Row] \ DbRead + RawSql =
        RawSql.allow(sql);
        SqlRead.fetch(sql, params) |> orRaise

    ///
    /// INSERT / UPDATE / DELETE を発行して影響行数を返す。
    ///
    pub def execute(sql: String, params: List[SqlValue]): Int32 \ DbWrite + RawSql =
        RawSql.allow(sql);
        SqlWrite.execute(sql, params) |> orRaise

    ///
    /// 書いた上で返る行（RETURNING）を全部返す。
    ///
    pub def executeReturning(sql: String, params: List[SqlValue]): List[Row] \ DbWrite + RawSql =
        RawSql.allow(sql);
        SqlWrite.executeReturning(sql, params) |> orRaise

    ///
    /// 先頭 1 行だけ返す。0 行なら None。2 行以上は先頭以外を捨てる（LIMIT 1 は SQL 側で書く）。
    ///
    pub def fetchOne(sql: String, params: List[SqlValue]): Option[Row] \ DbRead + RawSql =
        fetch(sql, params) |> List.head

    ///
    /// 全行をデコードして返す。デコード失敗は DbErr.decodeError（静かな半壊を許さない）。
    ///
    pub def fetchAs(decoder: Decoder[a], sql: String, params: List[SqlValue]): List[a] \ DbRead + RawSql =
        fetch(sql, params) |> Decoder.decodeRows(decoder) |> liftDecodeError

    ///
    /// 先頭 1 行をデコードして返す。0 行なら None。
    ///
    pub def fetchOneAs(decoder: Decoder[a], sql: String, params: List[SqlValue]): Option[a] \ DbRead + RawSql =
        fetchOne(sql, params)
            |> Option.map(row -> Decoder.decodeRow(decoder, row) |> liftDecodeError)

    ///
    /// 書いた上で返る行（RETURNING）を全部デコードする。
    ///
    pub def executeReturningAs(decoder: Decoder[a], sql: String, params: List[SqlValue]): List[a] \ DbWrite + RawSql =
        executeReturning(sql, params) |> Decoder.decodeRows(decoder) |> liftDecodeError

    ///
    /// 書いた上で返る行の先頭 1 行をデコードする。0 行なら None。
    ///
    pub def executeReturningOneAs(decoder: Decoder[a], sql: String, params: List[SqlValue]): Option[a] \ DbWrite + RawSql =
        executeReturning(sql, params)
            |> List.head
            |> Option.map(row -> Decoder.decodeRow(decoder, row) |> liftDecodeError)

    ///
    /// ハンドラが返した失敗を、呼び出し側の文脈で op にする。
    ///
    def orRaise(result: Result[DbError.DbErrorKind, a]): a \ {TransientDbErr, DbErr} = match result {
        case Ok(value) => value
        case Err(kind) => DbError.raise(kind)
    }

    ///
    /// Result のデコードエラーを DbErr.decodeError に持ち上げる。
    ///
    def liftDecodeError(result: Result[Decoder.DecodeError, a]): a \ DbErr = match result {
        case Ok(value) => value
        case Err(error) => DbErr.decodeError(Decoder.errorColumn(error), Decoder.describeError(error))
    }

}
