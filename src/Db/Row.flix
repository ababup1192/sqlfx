mod Row {

    ///
    /// 列名 → 添字。同じ結果セットの行はこれを共有する（行ごとに Map を持たない）。
    ///
    pub type alias ColumnIndex = Map[String, Int32]

    ///
    /// 結果セットの 1 行。接続からは切り離された不変の値。
    ///
    /// - `columns`: 列名 → 添字。結果セットの全行で共有する
    /// - `cells`: 列の値。添字は `columns` と対応する
    ///
    pub type alias Row = { columns = ColumnIndex, cells = Vector[SqlValue.SqlValue] }

    ///
    /// 発行した文。計測ハンドラが記録し、テストで比較する。
    ///
    /// - `sql`: プレースホルダを含む SQL 文
    /// - `params`: プレースホルダに渡した値。順序は `$1`, `$2`, ... と対応する
    ///
    pub type alias Statement = { sql = String, params = List[SqlValue.SqlValue] }

    ///
    /// 列名のリストから列名 → 添字の Map を組む。
    ///
    pub def makeColumnIndex(names: List[String]): ColumnIndex =
        names
            |> List.zipWithIndex
            |> List.map(match (index, name) -> (name, index))
            |> List.toMap

    ///
    /// 列名のリストと各行のセルから結果セットを組む。テストハンドラと JDBC ハンドラの両方が使う。
    ///
    pub def makeRows(names: List[String], cells: List[List[SqlValue.SqlValue]]): List[Row] =
        let columns = makeColumnIndex(names);
        cells |> List.map(rowCells -> { columns = columns, cells = List.toVector(rowCells) })

    ///
    /// 列名で値を取り出す。列が無ければ None。
    ///
    pub def get(name: String, row: Row): Option[SqlValue.SqlValue] =
        Map.get(name, row#columns) |> Option.flatMap(index -> Vector.nth(index, row#cells))

    ///
    /// 1 列の値を差し替えた行を返す。列が無ければ末尾に足す。
    /// テストで「この列だけ壊れた行」を作るのに使う。
    ///
    pub def set(name: String, value: SqlValue.SqlValue, row: Row): Row =
        match Map.get(name, row#columns) {
            case Some(index) if index >= Vector.length(row#cells) => bug!("Row.set: column '${name}' has index ${index} but the row has ${Vector.length(row#cells)} cells")
            case Some(index) => { columns = row#columns, cells = Vector.update(index, value, row#cells) }
            case None =>
                let index = Vector.length(row#cells);
                { columns = Map.insert(name, index, row#columns), cells = Vector.append(row#cells, Vector#{value}) }
        }

    ///
    /// 列名を添字の順で返す。
    ///
    pub def columnNames(row: Row): List[String] =
        row#columns
            |> Map.toList
            |> List.sortBy(snd)
            |> List.map(fst)

}
