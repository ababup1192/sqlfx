///
/// `.q` ファイル 1 本を読んだ結果（AST）。パーサが作り、生成器と render が読む。
///
mod QueryDef {

    ///
    /// 戻り形。`one` は Option[Row]、`many` は List[Row]、`exec` は Int32（影響行数）に対応する。
    ///
    pub enum Shape with Eq, Order, ToString {
        case One
        case Many
        case Exec
    }

    ///
    /// `{slot}` に入れられる断片の種類（design.md §5）。
    ///
    pub enum SlotKind with Eq, Order, ToString {
        /// WHERE に足す述語。`Pred[table]`
        case Pred
        /// ORDER BY。`Order[table]`
        case Order
    }

    ///
    /// SQL 本文を、素の文字列 / `:name` / `{slot}` に切った断片。
    ///
    pub enum Segment with Eq, Order, ToString {
        /// そのまま出力する SQL
        case Text(String)
        /// `:name`。引数への名前参照
        case ParamRef(String)
        /// `{name}`。断片 DSL の差し込み口
        case SlotRef(String)
    }

    ///
    /// 宣言した引数 1 つ。
    ///
    /// - `name`: `:name` で参照する名前
    /// - `paramType`: 型
    ///
    pub type alias Param = { name = String, paramType = SqlType.SqlType }

    ///
    /// `with` 節で宣言した slot 1 つ。
    ///
    /// - `name`: `{name}` で参照する名前
    /// - `kind`: Pred か Order か
    /// - `table`: `Pred[users]` の `users`。どのテーブルの列を参照できるか
    ///
    pub type alias Slot = { name = String, kind = SlotKind, table = String }

    ///
    /// `query` 1 つ。
    ///
    /// - `name`: 生成する関数名
    /// - `params`: 宣言順の引数
    /// - `shape`: 戻り形
    /// - `keyed`: `keyed(col)` の列名。preloader 用。無ければ None
    /// - `slots`: `with` 節の slot
    /// - `body`: SQL 本文の断片列
    ///
    pub type alias Query = { name = String, params = List[Param], shape = Shape, keyed = Option[String], slots = List[Slot], body = List[Segment] }

}
