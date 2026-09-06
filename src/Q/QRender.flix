///
/// AST を完全な SQL に戻す（design.md §3「機械置換で完全な SQL に戻る」）。
/// EXPLAIN や DBA レビューに貼れる形と、生成器が埋め込む `$n` 形の 2 つを出す。
///
mod QRender {

    use QueryDef.Segment
    use QueryDef.SlotKind
    use QueryDef.Query

    ///
    /// `:name` を出現順の `$n` に置き、`{slot}` を空にした状態の SQL と、`$n` の順に並んだ引数名を返す。
    /// 同じ `:name` が 2 回出れば同じ `$n` を 2 回使う。
    /// Pred の slot は `TRUE`、Order の slot は空文字に置く。空文字は `ORDER BY` を .q 側に書かない前提
    /// （design.md §3 の例は `{order}` だけを置き、ORDER BY は断片が持つ）。
    ///
    pub def toSql(queryDef: Query): (String, List[String]) =
        let (parts, names) = List.foldLeft(step(queryDef), (Nil, Nil), queryDef#body);
        (List.reverse(parts) |> List.join(""), List.reverse(names))

    ///
    /// 1 断片を文字列にし、`:name` なら引数名の並びも更新する。並びは逆順で持つ。
    ///
    def step(queryDef: Query, state: (List[String], List[String]), segment: Segment): (List[String], List[String]) =
        let (parts, names) = state;
        match segment {
            case Segment.Text(text) => (text :: parts, names)
            case Segment.ParamRef(name) =>
                match List.indexOf(name, List.reverse(names)) {
                    case Some(index) => ("$${index + 1}" :: parts, names)
                    case None => ("$${List.length(names) + 1}" :: parts, name :: names)
                }
            case Segment.SlotRef(name) => (slotPlaceholder(queryDef, name) :: parts, names)
        }

    ///
    /// slot を空にしたときの置き文字。宣言に無い slot はパーサが弾くので、ここでは Pred 扱いにしない（空文字）。
    /// Changes も空文字。`SET updated_at = now(), ` のように壊れた SET 句になるが、QResolve は SET 句を読まないので困らない。
    ///
    def slotPlaceholder(queryDef: Query, name: String): String =
        queryDef#slots
            |> List.find(slot -> slot#name == name)
            |> Option.map(slot -> match slot#kind {
                case SlotKind.Pred => "TRUE"
                case SlotKind.Order => ""
                case SlotKind.Changes => ""
            })
            |> Option.getWithDefault("")

}
