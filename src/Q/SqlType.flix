///
/// 列と引数の型。`.q` の型名、PG の型名、SqlValue の case、生成する Flix の型を 1 か所で対応させる。
/// 型を足すときは enum・`all`・`spec` の 3 か所（と SqlValue の値と NullType / Decoder / JdbcConvert の値側と setNull の型）。
///
mod SqlType {

    pub enum SqlType with Eq, Order, ToString {
        case Bool
        case Int32
        case Int64
        case Float64
        case Decimal
        case Str
        case Bytes
        case Timestamp
        case Date
        case Uuid
        case Json
        /// `bigint[]` / `List[Int64]`（`= ANY(:ids)` 用）
        case Int64Array
        /// `text[]` / `List[String]`
        case StrArray
    }

    ///
    /// 1 つの型の対応表。
    ///
    /// - `flixName`: `.q` に書く綴り
    /// - `pgNames`: PG の型名（小文字、長さ指定は落とした物）。`serial` 系は integer / bigint として扱う
    /// - `flixType`: 生成コードに書く Flix の型
    ///
    pub type alias Spec = { flixName = String, pgNames = List[String], flixType = String }

    ///
    /// 全部の型。逆引き（綴り → 型）に使う。
    ///
    pub def all(): List[SqlType] = List#{
        SqlType.Bool, SqlType.Int32, SqlType.Int64, SqlType.Float64, SqlType.Decimal, SqlType.Str, SqlType.Bytes,
        SqlType.Timestamp, SqlType.Date, SqlType.Uuid, SqlType.Json, SqlType.Int64Array, SqlType.StrArray
    }

    pub def spec(sqlType: SqlType): Spec = match sqlType {
        case SqlType.Bool => { flixName = "Bool", pgNames = List#{"boolean", "bool"}, flixType = "Bool" }
        case SqlType.Int32 => { flixName = "Int32", pgNames = List#{"integer", "int", "int4", "serial", "smallint", "int2"}, flixType = "Int32" }
        case SqlType.Int64 => { flixName = "Int64", pgNames = List#{"bigint", "int8", "bigserial"}, flixType = "Int64" }
        case SqlType.Float64 => { flixName = "Float64", pgNames = List#{"double precision", "float8", "real", "float4"}, flixType = "Float64" }
        case SqlType.Decimal => { flixName = "BigDecimal", pgNames = List#{"numeric", "decimal"}, flixType = "BigDecimal" }
        case SqlType.Str => { flixName = "String", pgNames = List#{"text", "varchar", "character varying", "character", "char", "citext"}, flixType = "String" }
        case SqlType.Bytes => { flixName = "Bytes", pgNames = List#{"bytea"}, flixType = "Vector[Int8]" }
        case SqlType.Timestamp => { flixName = "Timestamp", pgNames = List#{"timestamp", "timestamptz", "timestamp with time zone", "timestamp without time zone"}, flixType = "Timestamp.Timestamp" }
        case SqlType.Date => { flixName = "Date", pgNames = List#{"date"}, flixType = "Date.Date" }
        case SqlType.Uuid => { flixName = "Uuid", pgNames = List#{"uuid"}, flixType = "Uuid.Uuid" }
        case SqlType.Json => { flixName = "Json", pgNames = List#{"json", "jsonb"}, flixType = "Util.Json.Json" }
        case SqlType.Int64Array => { flixName = "List[Int64]", pgNames = List#{"bigint[]", "int8[]"}, flixType = "List[Int64]" }
        case SqlType.StrArray => { flixName = "List[String]", pgNames = List#{"text[]", "varchar[]"}, flixType = "List[String]" }
    }

    ///
    /// `.q` に書く型名（Flix の綴り）から。知らない綴りは None。
    ///
    pub def fromFlixName(spelling: String): Option[SqlType] =
        List.find(sqlType -> spec(sqlType)#flixName == spelling, all())

    ///
    /// PG の型名（小文字、長さ指定 `(10, 2)` は落とした物）から。知らない型は None。
    ///
    pub def fromPgName(pgType: String): Option[SqlType] =
        List.find(sqlType -> List.memberOf(pgType, spec(sqlType)#pgNames), all())

    ///
    /// 生成コードに書く Flix の型。
    ///
    pub def toFlixType(sqlType: SqlType): String = spec(sqlType)#flixType

    ///
    /// 生成コードで列を読む Decoder の関数名。case 名の先頭を小文字にした物（`Decoder.int64Array`）。
    ///
    pub def decoderName(sqlType: SqlType): String =
        let caseName = ToString.toString(sqlType);
        "Decoder." + String.toLowerCase(String.takeLeft(1, caseName)) + String.dropLeft(1, caseName)

    ///
    /// 生成コードで値を SqlValue に包む関数の名前。基本型は case そのもの（`SqlValue.Int64Array`）、
    /// 意味を持つ型は中身を取り出す関数（`SqlValue.ofTimestamp`）。関数値としても呼び出しとしても使える。
    ///
    pub def wrapFunction(sqlType: SqlType): String = match sqlType {
        case SqlType.Timestamp => "SqlValue.ofTimestamp"
        case SqlType.Date => "SqlValue.ofDate"
        case SqlType.Uuid => "SqlValue.ofUuid"
        case SqlType.Json => "SqlValue.ofJson"
        case _ => "SqlValue." + ToString.toString(sqlType)
    }

    ///
    /// 生成コードで NULL に付ける型の綴り（`SqlValue.NullType.Str`）。`Option` の引数の None がこれになる。
    /// case 名は SqlValue.NullType と揃えてあるので、対応表を 2 つ持たない。
    ///
    pub def nullTypeValue(sqlType: SqlType): String = "SqlValue.NullType." + ToString.toString(sqlType)

}
