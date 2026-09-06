mod Decoder {

    ///
    /// 1 行を型付きの値に変える純粋関数。列名 → 添字の解決は行の `columns` で行う。
    ///
    pub enum Decoder[a](Row.Row -> Result[DecodeError, a])

    ///
    /// forA / forM で列を並べて組めるようにする。`Decoder.pure` / `ap` / `flatMap` の別名。
    ///
    /// WhyNot: trait の `f` は `\ ef` を許すが、デコーダは行を受け取ってから純粋に走るので、
    /// `f` の効果を構築時に起こすことはできない。ここでは `f` を純粋と見なして受ける（`unchecked_cast`）。
    /// forA の yield に効果のある式を書かないこと。書けば型は通るが、効果はデコード時に手続き的に起きる。
    ///
    instance Functor[Decoder] {
        pub def map(f: a -> b \ ef, decoder: Decoder[a]): Decoder[b] \ ef =
            checked_ecast(Decoder.map(unchecked_cast(f as a -> b), decoder))
    }

    instance Applicative[Decoder] {
        pub def point(value: a): Decoder[a] = Decoder.pure(value)
        pub def ap(function: Decoder[a -> b \ ef], argument: Decoder[a]): Decoder[b] \ ef =
            checked_ecast(Decoder.ap(argument, unchecked_cast(function as Decoder[a -> b])))
    }

    instance Monad[Decoder] {
        pub def flatMap(f: a -> Decoder[b] \ ef, decoder: Decoder[a]): Decoder[b] \ ef =
            checked_ecast(Decoder.flatMap(unchecked_cast(f as a -> Decoder[b]), decoder))
    }

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
    pub def typed(column: { name = String, expected = String }, extract: SqlValue.SqlValue -> Option[a]): Decoder[a] =
        let name = column#name;
        let expected = column#expected;
        Decoder.Decoder(row -> Row.get(name, row) |> Option.toOk(DecodeError.MissingColumn(name)) |> Result.flatMap(value ->
            if (SqlValue.isNull(value))
                Err(DecodeError.UnexpectedNull(name))
            else
                extract(value) |> Option.toOk(DecodeError.TypeMismatch(name, expected, SqlValue.typeName(value)))))

    pub def bool(name: String): Decoder[Bool] = typed({ name = name, expected = "Bool" }, SqlValue.asBool)
    pub def int32(name: String): Decoder[Int32] = typed({ name = name, expected = "Int32" }, SqlValue.asInt32)
    pub def int64(name: String): Decoder[Int64] = typed({ name = name, expected = "Int64" }, SqlValue.asInt64)
    pub def float64(name: String): Decoder[Float64] = typed({ name = name, expected = "Float64" }, SqlValue.asFloat64)
    pub def decimal(name: String): Decoder[BigDecimal] = typed({ name = name, expected = "Decimal" }, SqlValue.asDecimal)
    pub def str(name: String): Decoder[String] = typed({ name = name, expected = "Str" }, SqlValue.asStr)
    pub def bytes(name: String): Decoder[Vector[Int8]] = typed({ name = name, expected = "Bytes" }, SqlValue.asBytes)
    pub def timestamp(name: String): Decoder[Int64] = typed({ name = name, expected = "Timestamp" }, SqlValue.asTimestamp)
    pub def date(name: String): Decoder[Int32] = typed({ name = name, expected = "Date" }, SqlValue.asDate)
    pub def uuid(name: String): Decoder[String] = typed({ name = name, expected = "Uuid" }, SqlValue.asUuid)
    pub def json(name: String): Decoder[String] = typed({ name = name, expected = "Json" }, SqlValue.asJson)
    pub def int64Array(name: String): Decoder[List[Int64]] = typed({ name = name, expected = "Int64Array" }, SqlValue.asInt64Array)
    pub def strArray(name: String): Decoder[List[String]] = typed({ name = name, expected = "StrArray" }, SqlValue.asStrArray)

}
