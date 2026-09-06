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
    /// 制約の種類。違反したときに返る DbErr の op と対応する。
    ///
    pub enum ConstraintKind with Eq, Order, ToString {
        case Unique
        case ForeignKey
        case Check
    }

    ///
    /// 名前付きの制約 1 つ。
    ///
    /// - `name`: DDL の `CONSTRAINT name` か `CREATE UNIQUE INDEX name`。違反時に DB がこの名前で返す
    /// - `kind`: 種類
    ///
    pub type alias Constraint = { name = String, kind = ConstraintKind }

    ///
    /// テーブル 1 つ。列は宣言順。制約は名前付きの物だけ（NOT NULL と PRIMARY KEY は持たない）。
    ///
    pub type alias Table = { name = String, columns = List[Column], constraints = List[Constraint] }

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
    /// テーブルを 1 つ差し替える。無ければ None。
    ///
    def updateTable(tableName: String, change: Table -> Table, schema: Schema): Option[Schema] =
        findTable(tableName, schema) |> Option.map(table -> addTable(change(table), schema))

    ///
    /// 列を末尾に足す。テーブルが無ければ None。
    ///
    pub def addColumn(tableName: String, column: Column, schema: Schema): Option[Schema] =
        updateTable(tableName, table -> { columns = List.append(table#columns, List#{column}) | table }, schema)

    ///
    /// 列を消す。テーブルか列が無ければ None。
    ///
    pub def dropColumn(target: { table = String, column = String }, schema: Schema): Option[Schema] =
        findTable(target#table, schema)
            |> Option.flatMap(table -> findColumn(target#column, table))
            |> Option.flatMap(_ -> updateTable(target#table, table -> { columns = List.filter(col -> col#name != target#column, table#columns) | table }, schema))

    ///
    /// 制約を足す。同名があれば差し替える。テーブルが無ければ None。
    ///
    pub def addConstraint(tableName: String, constraint: Constraint, schema: Schema): Option[Schema] =
        updateTable(tableName, table -> { constraints = List.append(List.filter(c -> c#name != constraint#name, table#constraints), List#{constraint}) | table }, schema)

    ///
    /// 名前の制約を消す。テーブルが無ければ None。無い名前を消しても何も起きない。
    ///
    pub def dropConstraint(target: { table = String, constraint = String }, schema: Schema): Option[Schema] =
        updateTable(target#table, table -> { constraints = List.filter(c -> c#name != target#constraint, table#constraints) | table }, schema)

    ///
    /// 制約の名前を変える。種類はそのまま。テーブルが無ければ None。
    ///
    pub def renameConstraint(target: { table = String, oldName = String, newName = String }, schema: Schema): Option[Schema] =
        updateTable(target#table, table -> { constraints = List.map(c -> if (c#name == target#oldName) { name = target#newName, kind = c#kind } else c, table#constraints) | table }, schema)

    ///
    /// 名前の制約をどのテーブルからでも消す（DROP INDEX はテーブル名を持たない）。
    ///
    pub def dropConstraintAnywhere(constraintName: String, schema: Schema): Schema =
        Map.map(table -> { constraints = List.filter(c -> c#name != constraintName, table#constraints) | table }, schema)

    ///
    /// 名前の制約をどのテーブルでも改名する（ALTER INDEX ... RENAME TO はテーブル名を持たない）。
    ///
    pub def renameConstraintAnywhere(names: { oldName = String, newName = String }, schema: Schema): Schema =
        Map.map(table -> { constraints = List.map(c -> if (c#name == names#oldName) { name = names#newName, kind = c#kind } else c, table#constraints) | table }, schema)

}
