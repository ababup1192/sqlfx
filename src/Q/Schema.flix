///
/// 机上のスキーマ。migrations の DDL から組み、`.q` の名前と型の解決に使う（design.md §3 の「生成時」の検証）。
///
mod Schema {

    use SqlType.SqlType

    ///
    /// 列 1 つ。
    ///
    /// - `name`: 列名
    /// - `columnType`: 型。PG の型名がこのライブラリの型に無ければ None（その列は .q の結果に出せない）
    /// - `nullable`: NULL を許すか。NOT NULL か PRIMARY KEY なら false
    ///
    pub type alias Column = { name = String, columnType = Option[SqlType], nullable = Bool }

    ///
    /// テーブル 1 つ。列は宣言順。
    ///
    pub type alias Table = { name = String, columns = List[Column] }

    ///
    /// テーブル名 → テーブル。
    ///
    pub type alias Schema = Map[String, Table]

    pub def empty(): Schema = Map.empty()

    pub def findTable(name: String, schema: Schema): Option[Table] = Map.get(name, schema)

    pub def findColumn(column: String, table: Table): Option[Column] =
        List.find(col -> col#name == column, table#columns)

    pub def addTable(table: Table, schema: Schema): Schema = Map.insert(table#name, table, schema)

    pub def dropTable(name: String, schema: Schema): Schema = Map.remove(name, schema)

    ///
    /// 列を末尾に足す。テーブルが無ければ None。
    ///
    pub def addColumn(tableName: String, column: Column, schema: Schema): Option[Schema] =
        findTable(tableName, schema)
            |> Option.map(table -> addTable({ name = table#name, columns = List.append(table#columns, List#{column}) }, schema))

    ///
    /// 列を消す。テーブルか列が無ければ None。
    ///
    pub def dropColumn(target: { table = String, column = String }, schema: Schema): Option[Schema] =
        findTable(target#table, schema)
            |> Option.flatMap(table -> findColumn(target#column, table) |> Option.map(_ -> table))
            |> Option.map(table -> addTable({ name = table#name, columns = List.filter(col -> col#name != target#column, table#columns) }, schema))

}
