mod SqlValue {

    ///
    /// プレースホルダに渡す値と、結果セットのセルの値。行きと帰りで同じ型を使い、JDBC との型対応表を 1 つにする。
    ///
    /// WhyNot: Timestamp を `OffsetDateTime`、Decimal を `java.math.BigDecimal` で持たないのは、
    /// Java 型を payload に置くと `Eq` を derive できず、テストハンドラが記録した Statement を比較できなくなるから。
    /// Java 型との変換は JDBC ハンドラの内側に閉じる。
    ///
    pub enum SqlValue with Eq, Order, ToString {
        /// SQL の NULL
        case Null
        case Bool(Bool)
        case Int32(Int32)
        case Int64(Int64)
        case Float64(Float64)
        /// NUMERIC。金額など精度が要る列
        case Decimal(BigDecimal)
        case Str(String)
        /// BYTEA
        case Bytes(Vector[Int8])
        /// TIMESTAMPTZ。UTC の epoch マイクロ秒
        case Timestamp(Int64)
        /// DATE。1970-01-01 からの日数
        case Date(Int32)
        /// UUID の 36 文字の文字列表現
        case Uuid(String)
        /// JSON / JSONB の素の文字列
        case Json(String)
        /// BIGINT[]。`ANY(:ids)` 用
        case Int64Array(List[Int64])
        /// TEXT[]
        case StrArray(List[String])
    }

    // ---- 意味を持つ型からの包み。生成コードと Col が使う ----

    pub def ofTimestamp(t: Timestamp.Timestamp): SqlValue = SqlValue.Timestamp(Timestamp.toEpochMicros(t))
    pub def ofDate(d: Date.Date): SqlValue = SqlValue.Date(Date.toEpochDay(d))
    pub def ofUuid(u: Uuid.Uuid): SqlValue = SqlValue.Uuid(Uuid.toText(u))
    pub def ofJson(j: Util.Json.Json): SqlValue = SqlValue.Json(Util.Json.toCompactString(j))

    ///
    /// デコーダのエラーメッセージに出す型名。
    ///
    pub def typeName(value: SqlValue): String = match value {
        case SqlValue.Null => "NULL"
        case SqlValue.Bool(_) => "Bool"
        case SqlValue.Int32(_) => "Int32"
        case SqlValue.Int64(_) => "Int64"
        case SqlValue.Float64(_) => "Float64"
        case SqlValue.Decimal(_) => "Decimal"
        case SqlValue.Str(_) => "Str"
        case SqlValue.Bytes(_) => "Bytes"
        case SqlValue.Timestamp(_) => "Timestamp"
        case SqlValue.Date(_) => "Date"
        case SqlValue.Uuid(_) => "Uuid"
        case SqlValue.Json(_) => "Json"
        case SqlValue.Int64Array(_) => "Int64Array"
        case SqlValue.StrArray(_) => "StrArray"
    }

    ///
    /// NULL かどうか。
    ///
    pub def isNull(value: SqlValue): Bool = match value {
        case SqlValue.Null => true
        case _ => false
    }

    ///
    /// Bool の値を取り出す。型が違えば None。
    ///
    pub def asBool(value: SqlValue): Option[Bool] = match value {
        case SqlValue.Bool(b) => Some(b)
        case _ => None
    }

    ///
    /// Int32 の値を取り出す。型が違えば None。
    ///
    pub def asInt32(value: SqlValue): Option[Int32] = match value {
        case SqlValue.Int32(i) => Some(i)
        case _ => None
    }

    ///
    /// Int64 の値を取り出す。Int32 の列も広げて返す（SERIAL と BIGSERIAL を区別せず読めるように）。
    ///
    pub def asInt64(value: SqlValue): Option[Int64] = match value {
        case SqlValue.Int64(i) => Some(i)
        case SqlValue.Int32(i) => Some(Int32.toInt64(i))
        case _ => None
    }

    ///
    /// Float64 の値を取り出す。型が違えば None。
    ///
    pub def asFloat64(value: SqlValue): Option[Float64] = match value {
        case SqlValue.Float64(f) => Some(f)
        case _ => None
    }

    ///
    /// Decimal の値を取り出す。型が違えば None。
    ///
    pub def asDecimal(value: SqlValue): Option[BigDecimal] = match value {
        case SqlValue.Decimal(d) => Some(d)
        case _ => None
    }

    ///
    /// 文字列の値を取り出す。型が違えば None。
    ///
    pub def asStr(value: SqlValue): Option[String] = match value {
        case SqlValue.Str(s) => Some(s)
        case _ => None
    }

    ///
    /// BYTEA の値を取り出す。型が違えば None。
    ///
    pub def asBytes(value: SqlValue): Option[Vector[Int8]] = match value {
        case SqlValue.Bytes(b) => Some(b)
        case _ => None
    }

    ///
    /// Timestamp（epoch マイクロ秒）を取り出す。型が違えば None。
    ///
    pub def asTimestamp(value: SqlValue): Option[Int64] = match value {
        case SqlValue.Timestamp(t) => Some(t)
        case _ => None
    }

    ///
    /// Date（1970-01-01 からの日数）を取り出す。型が違えば None。
    ///
    pub def asDate(value: SqlValue): Option[Int32] = match value {
        case SqlValue.Date(d) => Some(d)
        case _ => None
    }

    ///
    /// UUID の文字列表現を取り出す。型が違えば None。
    ///
    pub def asUuid(value: SqlValue): Option[String] = match value {
        case SqlValue.Uuid(u) => Some(u)
        case _ => None
    }

    ///
    /// JSON の素の文字列を取り出す。型が違えば None。
    ///
    pub def asJson(value: SqlValue): Option[String] = match value {
        case SqlValue.Json(j) => Some(j)
        case _ => None
    }

    ///
    /// BIGINT[] を取り出す。型が違えば None。
    ///
    pub def asInt64Array(value: SqlValue): Option[List[Int64]] = match value {
        case SqlValue.Int64Array(xs) => Some(xs)
        case _ => None
    }

    ///
    /// TEXT[] を取り出す。型が違えば None。
    ///
    pub def asStrArray(value: SqlValue): Option[List[String]] = match value {
        case SqlValue.StrArray(xs) => Some(xs)
        case _ => None
    }

}
