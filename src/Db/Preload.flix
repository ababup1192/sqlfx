///
/// IN 句バッチの preload の後始末。「親の列」と「子の列」を親のキーで束ねる。
/// 子は元の順のまま（クエリの ORDER BY がそのまま効く）、子の無い親は Nil。
///
/// WhyNot: Map の畳み込みを利用者に書かせないのは、`insertWith` の引数順と逆順の反転を毎回考えることになるから。
/// `keyed` からの preloader 生成（フェーズ 3）もこれを呼ぶ。
///
mod Preload {

    ///
    /// 子をキーで束ねる。同じキーの子は元の順。
    ///
    pub def groupBy(key: child -> k, children: List[child]): Map[k, List[child]] with Order[k] =
        children
            |> List.foldLeft((acc, child) -> Map.insertWith((newer, older) -> List.append(newer, older), key(child), List#{child}, acc), Map.empty())
            |> Map.map(List.reverse)

    ///
    /// 親ごとに、その親のキーに合う子を付ける。戻りは親の順。
    ///
    /// - `parents`: 親の列
    /// - `parentKey`: 親からキーを取る
    /// - `children`: 子の列（1 つの IN 句で取った物）
    /// - `childKey`: 子から親のキーを取る
    ///
    pub def attach(args: { parents = List[parent], parentKey = parent -> k, children = List[child], childKey = child -> k }): List[(parent, List[child])] with Order[k] =
        let byKey = groupBy(args#childKey, args#children);
        List.map(parent -> (parent, Map.getWithDefault(args#parentKey(parent), Nil, byKey)), args#parents)

}
