///
/// SqlValue と JDBC の型の変換。Java の型はこのモジュールの中に閉じる。
///
mod JdbcConvert {

    import java.lang.Long
    import java.lang.Object

    import java.sql.{Array => SqlArray}
    import java.sql.Connection
    import java.sql.{Date => SqlDate}
    import java.sql.PreparedStatement
    import java.sql.ResultSet
    import java.sql.ResultSetMetaData
    import java.sql.{Timestamp => SqlTimestamp}
    import java.sql.Types
    import java.time.Instant
    import java.time.LocalDate
    import java.time.OffsetDateTime
    import java.time.ZoneOffset
    import java.util.UUID
    import org.postgresql.util.PGobject

    use SqlValue.SqlValue
    use Row.Row

    ///
    /// `$1` 形式のプレースホルダを JDBC の `?` に書き換え、出現順に並べ直したパラメータを返す。
    /// 同じ `$n` が 2 回出れば同じ値を 2 回並べる。単一引用符の文字列リテラルの中は触らない。
    /// 存在しない `$n` を参照していたら None（バインド時の範囲外エラーより先に、ここで派手に落とす）。
    ///
    /// WhyNot: 利用側に `?` を書かせないのは、`$1` のままなら SQL をそのまま psql / EXPLAIN に貼れるから（design.md §3）。
    ///
    pub def rewritePlaceholders(sql: String, params: List[SqlValue]): Option[(String, List[SqlValue])] =
        let paramVector = List.toVector(params);
        let (chars, refs, _, pending) = String.toList(stripLineComments(sql)) |> List.foldLeft(step, (Nil, Nil, false, None));
        let (flushedChars, flushedRefs) = flushDigits(chars, refs, pending);
        let sqlOut = region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(ch -> StringBuilder.append(ch, sb), List.reverse(flushedChars));
            StringBuilder.toString(sb)
        };
        List.reverse(flushedRefs)
            |> List.traverse(n -> Vector.nth(n - 1, paramVector))
            |> Option.map(ordered -> (sqlOut, ordered))

    ///
    /// 1 文字ずつ見て (出力文字の逆順, 参照した $n の逆順, 引用符の中か, 読みかけの $n の数字)。
    ///
    def step(state: (List[Char], List[Int32], Bool, Option[Int32]), ch: Char): (List[Char], List[Int32], Bool, Option[Int32]) =
        let (chars, refs, inQuote, digits) = state;
        match digits {
            case Some(n) if Char.isDigit(ch) => (chars, refs, inQuote, Some(n * 10 + Char.digit(radix = 10, ch) |> Option.getWithDefault(0)))
            case Some(_) =>
                let (flushedChars, flushedRefs) = flushDigits(chars, refs, digits);
                step((flushedChars, flushedRefs, inQuote, None), ch)
            case None =>
                if (ch == '\'')
                    (ch :: chars, refs, not inQuote, None)
                else if (ch == '$' and not inQuote)
                    (chars, refs, inQuote, Some(0))
                else
                    (ch :: chars, refs, inQuote, None)
        }

    ///
    /// `--` から行末までを落とす。コメントの中の `'` や `$1` を見ないため。単一引用符の中の `--` は残す。
    ///
    pub def stripLineComments(sql: String): String =
        let (chars, _, _) = String.toList(sql) |> List.foldLeft(commentStep, (Nil, false, false));
        List.reverse(chars) |> charsToString

    ///
    /// (出力の逆順, 引用符の中か, コメントの中か)。
    ///
    def commentStep(state: (List[Char], Bool, Bool), ch: Char): (List[Char], Bool, Bool) =
        let (chars, inQuote, inComment) = state;
        if (inComment)
            (if (ch == '\n') ch :: chars else chars, false, ch != '\n')
        else if (ch == '\'')
            (ch :: chars, not inQuote, false)
        else if (ch == '-' and not inQuote)
            match chars {
                case '-' :: rest => (rest, false, true)
                case _ => (ch :: chars, inQuote, false)
            }
        else
            (ch :: chars, inQuote, false)

    def charsToString(chars: List[Char]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(c -> StringBuilder.append(c, sb), chars);
            StringBuilder.toString(sb)
        }

    ///
    /// 読みかけの `$n` を確定する。数字が無い `$` はそのまま出力に戻す（`$$` の dollar quote 等）。
    ///
    def flushDigits(chars: List[Char], refs: List[Int32], digits: Option[Int32]): (List[Char], List[Int32]) =
        match digits {
            case Some(0) => ('$' :: chars, refs)
            case Some(n) => ('?' :: chars, n :: refs)
            case None => (chars, refs)
        }

    ///
    /// プレースホルダに値を順に埋める。添字は JDBC に合わせて 1 始まり。
    ///
    pub def bindParams(conn: Connection, statement: PreparedStatement, params: List[SqlValue]): Unit \ IO =
        List.forEachWithIndex((index, value) -> bindParam(conn, statement, index + 1, value), params)

    ///
    /// プレースホルダ 1 つに値を埋める。
    ///
    /// WhyNot: Timestamp を `setTimestamp` にしないのは、あれは JVM のタイムゾーンで解釈されて
    /// TIMESTAMPTZ の instant がずれるから。`OffsetDateTime` を `setObject` すれば pgjdbc が UTC のまま送る。
    ///
    def bindParam(conn: Connection, statement: PreparedStatement, index: Int32, value: SqlValue): Unit \ IO =
        match value {
            case SqlValue.Null => statement.setNull(index, Types.NULL)
            case SqlValue.NullOf(nullType) => statement.setNull(index, jdbcType(nullType))
            case SqlValue.Bool(b) => statement.setBoolean(index, b)
            case SqlValue.Int32(i) => statement.setInt(index, i)
            case SqlValue.Int64(i) => statement.setLong(index, i)
            case SqlValue.Float64(f) => statement.setDouble(index, f)
            case SqlValue.Decimal(d) => statement.setBigDecimal(index, d)
            case SqlValue.Str(s) => statement.setString(index, s)
            case SqlValue.Bytes(bytes) => region rc {
                statement.setBytes(index, Vector.toArray(rc, bytes))
            }
            case SqlValue.Timestamp(micros) => statement.setObject(index, toOffsetDateTime(micros))
            case SqlValue.Date(days) => statement.setObject(index, LocalDate.ofEpochDay(Int32.toInt64(days)))
            case SqlValue.Uuid(s) => statement.setObject(index, UUID.fromString(s))
            case SqlValue.Json(s) => statement.setObject(index, toPgJsonb(s))
            case SqlValue.Int64Array(xs) => region rc {
                let boxed: Array[Object, rc] = Array.empty(rc, List.length(xs));
                List.forEachWithIndex((i, x) -> Array.put(checked_cast(Long.valueOf(x)), i, boxed), xs);
                statement.setArray(index, conn.createArrayOf("bigint", boxed))
            }
            case SqlValue.StrArray(xs) => region rc {
                let boxed: Array[Object, rc] = Array.empty(rc, List.length(xs));
                List.forEachWithIndex((i, x) -> Array.put(checked_cast(x), i, boxed), xs);
                statement.setArray(index, conn.createArrayOf("text", boxed))
            }
        }

    ///
    /// 型の付いた NULL を送るときの `java.sql.Types`。pgjdbc がここから oid を決める。
    ///
    /// WhyNot: uuid / json / 配列を `Types.OTHER` にするのは、JDBC にその型の定数が無く、
    /// pgjdbc が OTHER を「型を指定しない NULL」に写すから。列に入れる位置なら PG が列の型で解決する。
    ///
    def jdbcType(nullType: SqlValue.NullType): Int32 = match nullType {
        case SqlValue.NullType.Bool => Types.BOOLEAN
        case SqlValue.NullType.Int32 => Types.INTEGER
        case SqlValue.NullType.Int64 => Types.BIGINT
        case SqlValue.NullType.Float64 => Types.DOUBLE
        case SqlValue.NullType.Decimal => Types.NUMERIC
        case SqlValue.NullType.Str => Types.VARCHAR
        case SqlValue.NullType.Bytes => Types.VARBINARY
        case SqlValue.NullType.Timestamp => Types.TIMESTAMP_WITH_TIMEZONE
        case SqlValue.NullType.Date => Types.DATE
        case SqlValue.NullType.Uuid => Types.OTHER
        case SqlValue.NullType.Json => Types.OTHER
        case SqlValue.NullType.Int64Array => Types.ARRAY
        case SqlValue.NullType.StrArray => Types.ARRAY
    }

    ///
    /// 結果セットを全部読んで Row のリストにする。読み終わったら接続から独立した値になる。
    ///
    pub def materialize(resultSet: ResultSet): List[Row] \ IO =
        let metadata: ResultSetMetaData = resultSet.getMetaData();
        let count: Int32 = metadata.getColumnCount();
        let indices = List.range(1, count + 1);
        let names = indices |> List.map(i -> { let label: String = metadata.getColumnLabel(i); label });
        let columns = Row.makeColumnIndex(names);
        let readers = indices |> List.map(i -> cellReader(metadata, i));
        readRows(resultSet, columns, readers, Nil)

    ///
    /// 1 行ずつ next() で進めながら読む。先頭に積んで最後に反転する。
    ///
    def readRows(resultSet: ResultSet, columns: Row.ColumnIndex, readers: List[ResultSet -> SqlValue \ IO], acc: List[Row]): List[Row] \ IO =
        if (resultSet.next()) {
            let cells = readers |> List.map(read -> read(resultSet)) |> List.toVector;
            readRows(resultSet, columns, readers, { columns = columns, cells = cells } :: acc)
        } else
            List.reverse(acc)

    ///
    /// 列の JDBC 型から、その列を読む関数を 1 回だけ決める（行ごとに型を見ない）。
    /// NULL 判定はどの型でも `wasNull` で行う。
    ///
    /// WhyNot: 知らない型を `getString` で文字列にして返さないのは、静かな半壊（数値のつもりが文字列）を
    /// 許さない方針だから。読めない型は Corrupt として派手に落とす。
    ///
    def cellReader(metadata: ResultSetMetaData, index: Int32): (ResultSet -> SqlValue \ IO) \ IO =
        let jdbcType: Int32 = metadata.getColumnType(index);
        let typeName: String = metadata.getColumnTypeName(index);
        if (jdbcType == Types.BIT or jdbcType == Types.BOOLEAN)
            rs -> nullOr(rs, SqlValue.Bool(rs.getBoolean(index)))
        else if (jdbcType == Types.SMALLINT or jdbcType == Types.INTEGER or jdbcType == Types.TINYINT)
            rs -> nullOr(rs, SqlValue.Int32(rs.getInt(index)))
        else if (jdbcType == Types.BIGINT)
            rs -> nullOr(rs, SqlValue.Int64(rs.getLong(index)))
        else if (jdbcType == Types.NUMERIC or jdbcType == Types.DECIMAL)
            rs -> { let d: BigDecimal = rs.getBigDecimal(index); nullOr(rs, SqlValue.Decimal(d)) }
        else if (jdbcType == Types.REAL or jdbcType == Types.FLOAT or jdbcType == Types.DOUBLE)
            rs -> nullOr(rs, SqlValue.Float64(rs.getDouble(index)))
        else if (jdbcType == Types.CHAR or jdbcType == Types.VARCHAR or jdbcType == Types.LONGVARCHAR)
            rs -> { let s: String = rs.getString(index); nullOr(rs, SqlValue.Str(s)) }
        else if (jdbcType == Types.BINARY or jdbcType == Types.VARBINARY or jdbcType == Types.LONGVARBINARY)
            rs -> { let bytes: Array[Int8, Static] = rs.getBytes(index); nullOrConvert(rs, () -> SqlValue.Bytes(Array.toVector(bytes))) }
        else if (jdbcType == Types.TIMESTAMP or jdbcType == Types.TIMESTAMP_WITH_TIMEZONE)
            rs -> { let t: SqlTimestamp = rs.getTimestamp(index); nullOrConvert(rs, () -> SqlValue.Timestamp(fromSqlTimestamp(t))) }
        else if (jdbcType == Types.DATE)
            rs -> { let d: SqlDate = rs.getDate(index); nullOrConvert(rs, () -> SqlValue.Date(fromSqlDate(d))) }
        else if (jdbcType == Types.ARRAY and typeName == "_int8")
            rs -> { let a: SqlArray = rs.getArray(index); nullOrConvert(rs, () -> SqlValue.Int64Array(readInt64Array(a))) }
        else if (jdbcType == Types.ARRAY and typeName == "_text")
            rs -> { let a: SqlArray = rs.getArray(index); nullOrConvert(rs, () -> SqlValue.StrArray(readStrArray(a))) }
        else if (jdbcType == Types.OTHER and typeName == "uuid")
            rs -> { let s: String = rs.getString(index); nullOr(rs, SqlValue.Uuid(s)) }
        else if (jdbcType == Types.OTHER and (typeName == "json" or typeName == "jsonb"))
            rs -> { let s: String = rs.getString(index); nullOr(rs, SqlValue.Json(s)) }
        else
            rs -> { let s: String = rs.getString(index); nullOr(rs, SqlValue.Str(s)) }

    ///
    /// 直前の get* が NULL を読んでいたら Null、そうでなければ value。
    /// value は先に評価されている（get* の呼び出しが wasNull より前に済んでいる）ことに依存する。
    ///
    def nullOr(resultSet: ResultSet, value: SqlValue): SqlValue \ IO =
        if (resultSet.wasNull()) SqlValue.Null else value

    ///
    /// 変換が要る型用。NULL のときは変換を呼ばない（Java の null に触ると落ちる）。
    ///
    def nullOrConvert(resultSet: ResultSet, convert: Unit -> SqlValue \ IO): SqlValue \ IO =
        if (resultSet.wasNull()) SqlValue.Null else convert()

    ///
    /// SQL の配列を ResultSet 経由で読む（Object[] のキャストを避ける）。2 列目が値。
    ///
    def readInt64Array(sqlArray: SqlArray): List[Int64] \ IO =
        let rs: ResultSet = sqlArray.getResultSet();
        readArrayElements(rs, r -> r.getLong(2), Nil)

    def readStrArray(sqlArray: SqlArray): List[String] \ IO =
        let rs: ResultSet = sqlArray.getResultSet();
        readArrayElements(rs, r -> { let s: String = r.getString(2); s }, Nil)

    def readArrayElements(rs: ResultSet, read: ResultSet -> a \ IO, acc: List[a]): List[a] \ IO =
        if (rs.next())
            readArrayElements(rs, read, read(rs) :: acc)
        else
            List.reverse(acc)

    ///
    /// epoch マイクロ秒 → OffsetDateTime(UTC)。
    ///
    def toOffsetDateTime(micros: Int64): OffsetDateTime \ IO =
        let seconds = micros / 1000000i64;
        let nanos = (micros `Int64.remainder` 1000000i64) * 1000i64;
        OffsetDateTime.ofInstant(Instant.ofEpochSecond(seconds, nanos), ZoneOffset.UTC)

    ///
    /// java.sql.Timestamp → epoch マイクロ秒。Instant 経由なら 1970 年より前でも秒と秒未満の符号が揃う。
    ///
    def fromSqlTimestamp(t: SqlTimestamp): Int64 \ IO =
        let instant: Instant = t.toInstant();
        let seconds: Int64 = instant.getEpochSecond();
        let nanos: Int32 = instant.getNano();
        seconds * 1000000i64 + Int32.toInt64(nanos) / 1000i64

    ///
    /// java.sql.Date → 1970-01-01 からの日数。
    ///
    def fromSqlDate(d: SqlDate): Int32 \ IO =
        let local: LocalDate = d.toLocalDate();
        let days: Int64 = local.toEpochDay();
        Int64.clampToInt32(min = Int32.minValue(), max = Int32.maxValue(), days)

    ///
    /// jsonb として送る PGobject。
    ///
    def toPgJsonb(json: String): PGobject \ IO =
        let obj = new PGobject();
        obj.setType("jsonb");
        obj.setValue(json);
        obj

}
