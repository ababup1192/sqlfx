///
/// DB から読む境界。SELECT だけを発行する。
///
pub eff SqlRead {
    /// SQL とプレースホルダの値を渡し、結果セットを全部 materialize して返す
    def fetch(sql: String, params: List[SqlValue.SqlValue]): List[Row.Row]
}

///
/// DB へ書く境界。INSERT / UPDATE / DELETE を発行する。
///
pub eff SqlWrite {
    /// SQL とプレースホルダの値を渡し、影響行数を返す
    def execute(sql: String, params: List[SqlValue.SqlValue]): Int32
}

mod Sql {

    use SqlValue.SqlValue
    use Row.Row
    use Decoder.Decoder

    ///
    /// 先頭 1 行だけ返す。0 行なら None。2 行以上は先頭以外を捨てる（LIMIT 1 は SQL 側で書く）。
    ///
    pub def fetchOne(sql: String, params: List[SqlValue]): Option[Row] \ SqlRead =
        SqlRead.fetch(sql, params) |> List.head

    ///
    /// 全行をデコードして返す。デコード失敗は DbErr.decodeError（静かな半壊を許さない）。
    ///
    pub def fetchAs(decoder: Decoder[a], sql: String, params: List[SqlValue]): List[a] \ {SqlRead, DbErr} =
        SqlRead.fetch(sql, params) |> Decoder.decodeRows(decoder) |> liftDecodeError

    ///
    /// 先頭 1 行をデコードして返す。0 行なら None。
    ///
    pub def fetchOneAs(decoder: Decoder[a], sql: String, params: List[SqlValue]): Option[a] \ {SqlRead, DbErr} =
        fetchOne(sql, params)
            |> Option.map(row -> Decoder.decodeRow(decoder, row) |> liftDecodeError)

    ///
    /// Result のデコードエラーを DbErr.decodeError に持ち上げる。
    ///
    def liftDecodeError(result: Result[Decoder.DecodeError, a]): a \ DbErr = match result {
        case Ok(value) => value
        case Err(error) => DbErr.decodeError(Decoder.errorColumn(error), Decoder.describeError(error))
    }

}
