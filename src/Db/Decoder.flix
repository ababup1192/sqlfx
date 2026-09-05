mod Decoder {

    ///
    /// 1 行を型付きの値に変える純粋関数。列名 → 添字の解決は行の `columns` で行う。
    ///
    pub enum Decoder[a](Row.Row -> Result[DecodeError, a])

    ///
    /// デコードの失敗。列名と理由を持つ。
    ///
    pub enum DecodeError with Eq, Order, ToString {
        /// 列が結果セットに無い
        case MissingColumn(String)
        /// (列名, 期待した型, 実際の型)
        case TypeMismatch(String, String, String)
        /// NULL を許さない列が NULL だった
        case UnexpectedNull(String)
    }

    ///
    /// エラーメッセージ 1 行。`DbErr.decodeError` の detail に使う。
    ///
    pub def describeError(error: DecodeError): String = match error {
        case DecodeError.MissingColumn(column) => "column '${column}' is missing"
        case DecodeError.TypeMismatch(column, expected, actual) => "column '${column}' is ${actual}, expected ${expected}"
        case DecodeError.UnexpectedNull(column) => "column '${column}' is NULL"
    }

    ///
    /// エラーが起きた列名。
    ///
    pub def errorColumn(error: DecodeError): String = match error {
        case DecodeError.MissingColumn(column) => column
        case DecodeError.TypeMismatch(column, _, _) => column
        case DecodeError.UnexpectedNull(column) => column
    }

    ///
    /// 行を渡してデコードを走らせる。
    ///
    pub def decodeRow(decoder: Decoder[a], row: Row.Row): Result[DecodeError, a] =
        let Decoder.Decoder(decode) = decoder;
        decode(row)

    ///
    /// 全行をデコードする。最初に失敗した行のエラーを返す。
    ///
    pub def decodeRows(decoder: Decoder[a], rows: List[Row.Row]): Result[DecodeError, List[a]] =
        Result.traverse(decodeRow(decoder), rows)

    ///
    /// 行を見ずに値を返す。`ap` でレコードを組み立てる起点。
    ///
    pub def pure(value: a): Decoder[a] = Decoder.Decoder(_ -> Ok(value))

    ///
    /// デコード結果に関数を当てる。
    ///
    pub def map(f: a -> b, decoder: Decoder[a]): Decoder[b] =
        Decoder.Decoder(row -> decodeRow(decoder, row) |> Result.map(f))

    ///
    /// 関数を返すデコーダに引数のデコーダを当てる。複数列を 1 つのレコードへ組むときに `pure` から続けて使う。
    ///
    pub def ap(argument: Decoder[a], function: Decoder[a -> b]): Decoder[b] =
        Decoder.Decoder(row ->
            decodeRow(function, row) |> Result.flatMap(f -> decodeRow(argument, row) |> Result.map(f)))

    ///
    /// デコード結果から次のデコーダを決める。
    ///
    pub def flatMap(f: a -> Decoder[b], decoder: Decoder[a]): Decoder[b] =
        Decoder.Decoder(row -> decodeRow(decoder, row) |> Result.flatMap(value -> decodeRow(f(value), row)))

    ///
    /// 列を SqlValue のまま取り出す。列が無ければ MissingColumn。
    ///
    pub def column(name: String): Decoder[SqlValue.SqlValue] =
        Decoder.Decoder(row -> Row.get(name, row) |> Option.toOk(DecodeError.MissingColumn(name)))

    ///
    /// NULL を許す列。内側のデコーダが UnexpectedNull で失敗したら None、成功したら Some。
    ///
    /// WhyNot: Decoder に「見ている列名」を持たせて先に NULL 判定しないのは、`ap` で複数列を束ねた後の
    /// NULL 判定は定義できず、`opt` は列 1 つに対してだけ意味を持つから。UnexpectedNull を None に読み替えれば足りる。
    ///
    pub def opt(decoder: Decoder[a]): Decoder[Option[a]] =
        Decoder.Decoder(row -> match decodeRow(decoder, row) {
            case Err(DecodeError.UnexpectedNull(_)) => Ok(None)
            case Err(error) => Err(error)
            case Ok(value) => Ok(Some(value))
        })

    ///
    /// 型付きの列デコーダを組む。`extract` が None を返したら TypeMismatch、NULL なら UnexpectedNull。
    ///
    pub def typed(expected: String, extract: SqlValue.SqlValue -> Option[a], name: String): Decoder[a] =
        Decoder.Decoder(row -> Row.get(name, row) |> Option.toOk(DecodeError.MissingColumn(name)) |> Result.flatMap(value ->
            if (SqlValue.isNull(value))
                Err(DecodeError.UnexpectedNull(name))
            else
                extract(value) |> Option.toOk(DecodeError.TypeMismatch(name, expected, SqlValue.typeName(value)))))

    pub def bool(name: String): Decoder[Bool] = typed("Bool", SqlValue.asBool, name)
    pub def int32(name: String): Decoder[Int32] = typed("Int32", SqlValue.asInt32, name)
    pub def int64(name: String): Decoder[Int64] = typed("Int64", SqlValue.asInt64, name)
    pub def float64(name: String): Decoder[Float64] = typed("Float64", SqlValue.asFloat64, name)
    pub def decimal(name: String): Decoder[BigDecimal] = typed("Decimal", SqlValue.asDecimal, name)
    pub def str(name: String): Decoder[String] = typed("Str", SqlValue.asStr, name)
    pub def bytes(name: String): Decoder[Vector[Int8]] = typed("Bytes", SqlValue.asBytes, name)
    pub def timestamp(name: String): Decoder[Int64] = typed("Timestamp", SqlValue.asTimestamp, name)
    pub def date(name: String): Decoder[Int32] = typed("Date", SqlValue.asDate, name)
    pub def uuid(name: String): Decoder[String] = typed("Uuid", SqlValue.asUuid, name)
    pub def json(name: String): Decoder[String] = typed("Json", SqlValue.asJson, name)
    pub def int64Array(name: String): Decoder[List[Int64]] = typed("Int64Array", SqlValue.asInt64Array, name)
    pub def strArray(name: String): Decoder[List[String]] = typed("StrArray", SqlValue.asStrArray, name)

}
