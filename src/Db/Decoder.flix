mod Decoder {

    use Util.Json.FromJson.FromJson

    ///
    /// 1 行を型付きの値に変える純粋関数と、その値を読むのに要る SELECT 句の断片の一覧（逆順で持つ）。
    /// 列名 → 添字の解決は行の `columns` で行う。断片の一覧は `selectClause` で SELECT 句を組むのに使う。
    ///
    /// WhyNot: 断片を逆順で持つのは、`ap` で連結するときに長い側（function）をコピーしないため。
    ///
    pub enum Decoder[a] {
        case Decoder(List[String], Row.Row -> Result[DecodeError, a])
    }

    ///
    /// forA で列を並べて組めるようにする。`Decoder.pure` / `ap` の別名。Monad にはしない（後述）。
    ///
    /// WhyNot: trait の `f` は `\ ef` を許すが、デコーダは行を受け取ってから純粋に走るので、
    /// `f` の効果を構築時に起こすことはできない。ここでは `f` を純粋と見なして受ける（`unchecked_cast`）。
    /// forA の yield に効果のある式を書かないこと。書けば型は通るが、効果はデコード時に手続き的に起きる。
    ///
    /// WhyNot: `Monad`（`flatMap`）を付けないのは、次に読む列が値で決まると SELECT 句を静的に組めなくなるから。
    /// 値で分岐したいときは `column` で SqlValue を取り、`map` の中で分岐する。
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
        /// (列名, 理由) JSON として読めない。`json` 型の列では起きず、TEXT 列を Json と宣言したときに出る
        case InvalidJson(String, String)
    }

    ///
    /// エラーメッセージ 1 行。`DbErr.decodeError` の detail に使う。
    ///
    pub def describeError(error: DecodeError): String = match error {
        case DecodeError.MissingColumn(column) => "column '${column}' is missing"
        case DecodeError.TypeMismatch(column, expected, actual) => "column '${column}' is ${actual}, expected ${expected}"
        case DecodeError.UnexpectedNull(column) => "column '${column}' is NULL"
        case DecodeError.InvalidJson(column, reason) => "column '${column}' is not JSON: ${reason}"
    }

    ///
    /// エラーが起きた列名。
    ///
    pub def errorColumn(error: DecodeError): String = match error {
        case DecodeError.MissingColumn(column) => column
        case DecodeError.TypeMismatch(column, _, _) => column
        case DecodeError.InvalidJson(column, _) => column
        case DecodeError.UnexpectedNull(column) => column
    }

    ///
    /// 行を渡してデコードを走らせる。
    ///
    pub def decodeRow(decoder: Decoder[a], row: Row.Row): Result[DecodeError, a] =
        let Decoder.Decoder(_, decode) = decoder;
        decode(row)

    ///
    /// 全行をデコードする。最初に失敗した行のエラーを返す。
    ///
    pub def decodeRows(decoder: Decoder[a], rows: List[Row.Row]): Result[DecodeError, List[a]] =
        Result.traverse(decodeRow(decoder), rows)

    // ---- SELECT 句 ----

    ///
    /// このデコーダが読む SELECT 句の断片を、`forA` に並べた順で。同じ断片は 1 つにまとめる。
    ///
    pub def selectList(decoder: Decoder[a]): List[String] =
        let Decoder.Decoder(reversed, _) = decoder;
        List.reverse(reversed) |> List.distinct

    ///
    /// SELECT 句の中身（`id, name, email`）。生 SQL に `"SELECT ${Decoder.selectClause(d)} FROM ..."` と埋める。
    /// 列名を書くのがデコーダの 1 回だけになり、SELECT 句とデコーダのズレが起きない。
    ///
    pub def selectClause(decoder: Decoder[a]): String =
        selectList(decoder) |> List.join(", ")

    ///
    /// 式の列。内側のデコーダが読む列名をラベルにして `expr AS label` を SELECT 句に出す。
    /// `selectExpr("count(*)::bigint", Decoder.int64("total"))` は `count(*)::bigint AS total` を出し、`total` を Int64 で読む。
    /// JOIN の `selectExpr("u.name", Decoder.str("author_name"))` も同じ形。
    ///
    pub def selectExpr(expr: String, decoder: Decoder[a]): Decoder[a] =
        let Decoder.Decoder(reversed, decode) = decoder;
        Decoder.Decoder(List.map(label -> "${expr} AS ${label}", reversed), decode)

    // ---- 組み立て ----

    ///
    /// 行を見ずに値を返す。`ap` でレコードを組み立てる起点。列は読まない。
    ///
    pub def pure(value: a): Decoder[a] = Decoder.Decoder(Nil, _ -> Ok(value))

    ///
    /// デコード結果に関数を当てる。列はそのまま。
    ///
    pub def map(f: a -> b, decoder: Decoder[a]): Decoder[b] =
        let Decoder.Decoder(reversed, decode) = decoder;
        Decoder.Decoder(reversed, row -> decode(row) |> Result.map(f))

    ///
    /// 関数を返すデコーダに引数のデコーダを当てる。複数列を 1 つのレコードへ組むときに `pure` から続けて使う。
    /// 列は function の分が先、argument の分が後（forA に並べた順）。
    ///
    pub def ap(argument: Decoder[a], function: Decoder[a -> b]): Decoder[b] =
        let Decoder.Decoder(argumentReversed, decodeArgument) = argument;
        let Decoder.Decoder(functionReversed, decodeFunction) = function;
        Decoder.Decoder(List.append(argumentReversed, functionReversed), row ->
            decodeFunction(row) |> Result.flatMap(f -> decodeArgument(row) |> Result.map(f)))

    ///
    /// 列を SqlValue のまま取り出す。列が無ければ MissingColumn。
    ///
    pub def column(name: String): Decoder[SqlValue.SqlValue] =
        Decoder.Decoder(List#{name}, row -> Row.get(name, row) |> Option.toOk(DecodeError.MissingColumn(name)))

    ///
    /// NULL を許す列。内側のデコーダが UnexpectedNull で失敗したら None、成功したら Some。列はそのまま。
    ///
    /// WhyNot: 列名を見て先に NULL 判定しないのは、`ap` で複数列を束ねた後の NULL 判定は定義できず、
    /// `opt` は列 1 つに対してだけ意味を持つから。UnexpectedNull を None に読み替えれば足りる。
    ///
    pub def opt(decoder: Decoder[a]): Decoder[Option[a]] =
        let Decoder.Decoder(reversed, decode) = decoder;
        Decoder.Decoder(reversed, row -> match decode(row) {
            case Err(DecodeError.UnexpectedNull(_)) => Ok(None)
            case Err(error) => Err(error)
            case Ok(value) => Ok(Some(value))
        })

    ///
    /// 壊れた値を行ごと落とさず、失敗を値として残す。内側が TypeMismatch で失敗したら Err、成功したら Ok。列はそのまま。
    /// NULL は `opt` の役目、列が無い（MissingColumn）のは SELECT 句とデコーダのずれなので握らず落とす。
    ///
    /// WhyNot: Option にしないのは、None にした事実がどこにも残らず、汚染に気付く経路が消えるから。
    /// 件数の集計やログは、Err を持った利用者が組む。
    ///
    pub def attempt(decoder: Decoder[a]): Decoder[Result[DecodeError, a]] =
        let Decoder.Decoder(reversed, decode) = decoder;
        Decoder.Decoder(reversed, row -> match decode(row) {
            case Err(error) if isTypeMismatch(error) => Ok(Err(error))
            case Err(error) => Err(error)
            case Ok(value) => Ok(Ok(value))
        })

    def isTypeMismatch(error: DecodeError): Bool = match error {
        case DecodeError.TypeMismatch(_, _, _) => true
        case _ => false
    }

    ///
    /// 型付きの列デコーダを組む。`extract` が None を返したら TypeMismatch、NULL なら UnexpectedNull。
    ///
    pub def typed(column: { name = String, expected = String }, extract: SqlValue.SqlValue -> Option[a]): Decoder[a] =
        let name = column#name;
        let expected = column#expected;
        Decoder.Decoder(List#{name}, row -> Row.get(name, row) |> Option.toOk(DecodeError.MissingColumn(name)) |> Result.flatMap(value ->
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
    pub def timestamp(name: String): Decoder[Timestamp.Timestamp] = typed({ name = name, expected = "Timestamp" }, value -> SqlValue.asTimestamp(value) |> Option.map(Timestamp.fromEpochMicros))
    pub def date(name: String): Decoder[Date.Date] = typed({ name = name, expected = "Date" }, value -> SqlValue.asDate(value) |> Option.map(Date.fromEpochDay))
    pub def uuid(name: String): Decoder[Uuid.Uuid] = typed({ name = name, expected = "Uuid" }, value -> SqlValue.asUuid(value) |> Option.flatMap(Uuid.fromString))

    ///
    /// JSON の素の文字列。
    ///
    pub def jsonText(name: String): Decoder[String] = typed({ name = name, expected = "Json" }, SqlValue.asJson)

    ///
    /// 標準ライブラリの Json に parse する。読めなければ InvalidJson。
    ///
    pub def json(name: String): Decoder[Util.Json.Json] =
        let Decoder.Decoder(columns, decode) = jsonText(name);
        Decoder.Decoder(columns, row -> decode(row) |> Result.flatMap(text -> Util.Json.parse(text) |> Result.mapErr(e -> DecodeError.InvalidJson(name, "${e}"))))

    ///
    /// JSON を FromJson のある型に。形が合わなければ InvalidJson。
    ///
    pub def jsonAs(name: String): Decoder[a] with FromJson[a] =
        let Decoder.Decoder(columns, decode) = json(name);
        Decoder.Decoder(columns, row -> decode(row) |> Result.flatMap(j -> FromJson.fromJson(j) |> Result.mapErr(e -> DecodeError.InvalidJson(name, "${e}"))))
    pub def int64Array(name: String): Decoder[List[Int64]] = typed({ name = name, expected = "Int64Array" }, SqlValue.asInt64Array)
    pub def strArray(name: String): Decoder[List[String]] = typed({ name = name, expected = "StrArray" }, SqlValue.asStrArray)

}
