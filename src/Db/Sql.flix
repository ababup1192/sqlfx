///
/// DB から読む境界。SELECT だけを発行する。
/// op の戻りが Result なのは、ハンドラ本体で投げたエフェクトは呼び出し側の内側のハンドラには届かないから
/// （Flix のハンドラ本体は `run` の外側で評価される）。失敗は値で返し、`Sql.fetch` が呼び出し側の文脈で op に変える。
/// こうしておくと、アプリは `DbError.runWithKind` を自分の呼び出しの周りに被せて制約違反を拾える。
///
pub eff SqlRead {
    /// SQL とプレースホルダの値を渡し、結果セットを全部 materialize して返す
    def fetch(sql: String, params: List[SqlValue.SqlValue]): Result[DbError.DbErrorKind, List[Row.Row]]
}

///
/// DB へ書く境界。INSERT / UPDATE / DELETE を発行する。
///
pub eff SqlWrite {
    /// SQL とプレースホルダの値を渡し、影響行数を返す
    def execute(sql: String, params: List[SqlValue.SqlValue]): Result[DbError.DbErrorKind, Int32]
    /// `INSERT ... RETURNING` のように書いた上で行も返す文。結果セットを全部 materialize して返す
    def executeReturning(sql: String, params: List[SqlValue.SqlValue]): Result[DbError.DbErrorKind, List[Row.Row]]
}

///
/// 読む関数の効果。ハンドラが返した失敗は呼び出し側で op になる。
/// 生の SQL 文字列を渡す `Sql.*` にはさらに `RawSql` が付く。`.q` から生成した関数には付かない。
///
pub type alias DbRead = {SqlRead, TransientDbErr, DbErr}

///
/// 書く関数の効果。
///
pub type alias DbWrite = {SqlWrite, TransientDbErr, DbErr}

mod Sql {

    use SqlValue.SqlValue
    use Row.Row
    use Decoder.Decoder

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
