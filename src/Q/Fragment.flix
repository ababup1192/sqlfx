///
/// 断片 DSL（design.md §5）。`.q` の `{slot}` に入れる述語と並び順を、型付きの値として組む。
/// 値は必ずプレースホルダになり、識別子は Col を通した物しか出ないので、SQL インジェクションが構造的に起きない。
///
mod Fragment {

    // 利用者が呼ぶのは組み立ての関数と演算子（=== ... all / asc desc then）。render 系は生成コードが呼ぶ。
    // and / or / not は Flix の予約語なので both / either / negate と名付けている。

    use SqlValue.SqlValue

    ///
    /// 列が NULL を取らない印。`Col` の第 3 型パラメータに入る。
    ///
    pub enum NotNull {
        case NotNull
    }

    ///
    /// 列が NULL を取りうる印。`isNull` / `isNotNull` はこの印の列にだけ書ける。
    ///
    pub enum Nullable {
        case Nullable
    }

    ///
    /// 比較の右辺に置いた値の印。`value(x)` が付ける。`isNull` や `asc` には置けない。
    ///
    pub enum Literal {
        case Literal
    }

    ///
    /// 比較の項。テーブル `row` の型 `a` の列か、同じ型の値。
    /// `n` は列なら NotNull か Nullable（生成器が DDL から写す）、値なら Literal。
    /// `Col` の第 2 引数は値を SqlValue に包む関数。値の項はこの関数を持たないので、比較の左辺は必ず列。
    ///
    pub enum Col[_row: Type, a: Type, _n: Type] {
        case Col(String, a -> SqlValue)
        case Value(a)
    }

    ///
    /// `n` が列の印（NotNull / Nullable）である証拠。比較の左辺、isNull、asc / desc はこれを要求する。
    ///
    pub trait IsColumn[n: Type]

    instance IsColumn[NotNull]
    instance IsColumn[Nullable]

    ///
    /// 比較演算子。文字列で持たないのは、`render` が出す物を閉じた集合にするため。
    ///
    pub enum CompareOp with Eq, Order, ToString {
        case Eq
        case Ne
        case Lt
        case Le
        case Gt
        case Ge
        case Like
    }

    ///
    /// テーブル `row` の列だけを参照する述語。
    ///
    pub enum Pred[row: Type] {
        /// `TRUE`。`when` の条件が偽のときや、絞り込み無しのとき
        case Always
        /// `col op $n`
        case Compare(String, CompareOp, SqlValue)
        /// `col op col`。値を積まないので $n は進まない
        case CompareCols(String, CompareOp, String)
        case IsNull(String)
        case IsNotNull(String)
        /// `col IN ($n, ...)`。空なら FALSE
        case In(String, List[SqlValue])
        case And(Pred[row], Pred[row])
        case Or(Pred[row], Pred[row])
        case Not(Pred[row])
        /// 生 SQL。作るには RawSql エフェクトが要る
        case Raw(String)
    }

    ///
    /// テーブル `row` の列だけを参照する並び順。
    ///
    pub enum Order[row: Type] {
        /// ORDER BY を出さない
        case Unordered
        case Asc(String)
        case Desc(String)
        case Then(Order[row], Order[row])
    }

    // ---- 組み立て ----
    // WhyNot: and / or / not を関数名にしないのは Flix の予約語だから。both / either / negate で代える。

    ///
    /// 列の名前と、値を SqlValue に包む関数。IsColumn が付く所でしか呼ばないので Value には来ない。
    ///
    def column(col: Col[row, a, n]): (String, a -> SqlValue) with IsColumn[n] = match col {
        case Col.Col(name, toSql) => (name, toSql)
        case Col.Value(_) => bug!("Fragment: IsColumn の付いた項が値だった")
    }

    def colName(col: Col[row, a, n]): String with IsColumn[n] = fst(column(col))

    ///
    /// 比較の右辺に置く値。`UsersTable.id() === Fragment.value(3i64)`。SqlValue への変換は左辺の列が持つ。
    ///
    pub def value(x: a): Col[row, a, Literal] = Col.Value(x)

    // ---- 比較 ----
    // 左辺は列、右辺は列か値。型 a と row が一致しないと型エラー。nullability は一致しなくてよい。
    // WhyNot: > < >= <= == != を使わないのは、Flix でこれらが組み込みの比較に固定されていて定義し直せないから。
    // = と <> は Slick と同じ === / =!=、順序は文字を重ねる。`use Fragment.{>>}` を書いたスコープだけ Prelude の関数合成に勝つ。

    def compare(op: CompareOp, left: Col[row, a, n1], right: Col[row, a, n2]): Pred[row] with IsColumn[n1] =
        let (leftName, toSql) = column(left);
        match right {
            case Col.Col(rightName, _) => Pred.CompareCols(leftName, op, rightName)
            case Col.Value(x) => Pred.Compare(leftName, op, toSql(x))
        }

    pub def ===(left: Col[row, a, n1], right: Col[row, a, n2]): Pred[row] with IsColumn[n1] = compare(CompareOp.Eq, left, right)
    pub def =!=(left: Col[row, a, n1], right: Col[row, a, n2]): Pred[row] with IsColumn[n1] = compare(CompareOp.Ne, left, right)
    pub def <<(left: Col[row, a, n1], right: Col[row, a, n2]): Pred[row] with IsColumn[n1] = compare(CompareOp.Lt, left, right)
    pub def <<=(left: Col[row, a, n1], right: Col[row, a, n2]): Pred[row] with IsColumn[n1] = compare(CompareOp.Le, left, right)
    pub def >>(left: Col[row, a, n1], right: Col[row, a, n2]): Pred[row] with IsColumn[n1] = compare(CompareOp.Gt, left, right)
    pub def >>=(left: Col[row, a, n1], right: Col[row, a, n2]): Pred[row] with IsColumn[n1] = compare(CompareOp.Ge, left, right)

    pub def like(col: Col[row, String, n], pattern: String): Pred[row] with IsColumn[n] = Pred.Compare(colName(col), CompareOp.Like, SqlValue.Str(pattern))

    pub def inList(col: Col[row, a, n], values: List[a]): Pred[row] with IsColumn[n] =
        let (name, toSql) = column(col);
        Pred.In(name, List.map(toSql, values))

    ///
    /// `IS NULL`。Nullable の列にだけ書ける。NOT NULL の列や値には型エラーになる。
    ///
    pub def isNull(col: Col[row, a, Nullable]): Pred[row] = Pred.IsNull(colName(col))
    pub def isNotNull(col: Col[row, a, Nullable]): Pred[row] = Pred.IsNotNull(colName(col))
    ///
    /// 絞り込み無し（TRUE）。
    ///
    pub def always(): Pred[row] = Pred.Always

    ///
    /// AND。片方が `always` ならもう片方だけにする（`TRUE AND` を SQL に残さない）。
    ///
    pub def both(left: Pred[row], right: Pred[row]): Pred[row] = match (left, right) {
        case (Pred.Always, _) => right
        case (_, Pred.Always) => left
        case _ => Pred.And(left, right)
    }

    pub def either(left: Pred[row], right: Pred[row]): Pred[row] = Pred.Or(left, right)
    pub def negate(pred: Pred[row]): Pred[row] = Pred.Not(pred)

    ///
    /// 条件が真のときだけ述語を効かせる。偽なら TRUE。
    ///
    pub def when(condition: Bool, pred: Pred[row]): Pred[row] = if (condition) pred else Pred.Always

    ///
    /// 全部 AND で繋ぐ。空なら TRUE。
    ///
    pub def all(preds: List[Pred[row]]): Pred[row] = List.foldLeft(both, Pred.Always, preds)

    ///
    /// どれか 1 つ（OR で繋ぐ）。空なら TRUE（絞り込み無し）。
    ///
    pub def any(preds: List[Pred[row]]): Pred[row] =
        List.reduceLeft(either, preds) |> Option.getWithDefault(Pred.Always)

    ///
    /// 並び順無し（ORDER BY を出さない）。
    ///
    pub def unordered(): Order[row] = Order.Unordered

    ///
    /// 生 SQL を述語にする。RawSql が付くので、呼ぶ側の型に監査箇所が出る。
    ///
    pub def rawPred(sql: String): Pred[row] \ RawSql =
        RawSql.allow(sql);
        Pred.Raw(sql)

    pub def asc(col: Col[row, a, n]): Order[row] with IsColumn[n] = Order.Asc(colName(col))
    pub def desc(col: Col[row, a, n]): Order[row] with IsColumn[n] = Order.Desc(colName(col))
    pub def then(first: Order[row], second: Order[row]): Order[row] = Order.Then(first, second)

    // ---- render ----

    ///
    /// 述語を SQL とプレースホルダの値に落とす。`$n` は `firstIndex` から振る。括弧は全付け。
    ///
    pub def renderPred(pred: Pred[row], firstIndex: Int32): (String, List[SqlValue]) =
        let (sql, reversedParams, _) = renderLoop(pred, (Nil, firstIndex));
        (sql, List.reverse(reversedParams))

    ///
    /// 状態は (積んだ値の逆順, 次の $n)。
    ///
    def renderLoop(pred: Pred[row], state: (List[SqlValue], Int32)): (String, List[SqlValue], Int32) =
        let (params, next) = state;
        match pred {
            case Pred.Always => ("TRUE", params, next)
            case Pred.Compare(col, op, value) => ("(${col} ${opSql(op)} $${next})", value :: params, next + 1)
            case Pred.CompareCols(left, op, right) => ("(${left} ${opSql(op)} ${right})", params, next)
            case Pred.IsNull(col) => ("(${col} IS NULL)", params, next)
            case Pred.IsNotNull(col) => ("(${col} IS NOT NULL)", params, next)
            case Pred.In(_, Nil) => ("FALSE", params, next)
            case Pred.In(col, values) =>
                let count = List.length(values);
                let placeholders = List.range(next, next + count) |> List.map(n -> "$${n}") |> List.join(", ");
                ("(${col} IN (${placeholders}))", List.append(List.reverse(values), params), next + count)
            case Pred.And(left, right) => binary("AND", left, right, state)
            case Pred.Or(left, right) => binary("OR", left, right, state)
            case Pred.Not(inner) =>
                let (sql, innerParams, innerNext) = renderLoop(inner, state);
                ("(NOT ${sql})", innerParams, innerNext)
            case Pred.Raw(sql) => ("(${sql})", params, next)
        }

    def binary(keyword: String, left: Pred[row], right: Pred[row], state: (List[SqlValue], Int32)): (String, List[SqlValue], Int32) =
        let (leftSql, leftParams, leftNext) = renderLoop(left, state);
        let (rightSql, rightParams, rightNext) = renderLoop(right, (leftParams, leftNext));
        ("(${leftSql} ${keyword} ${rightSql})", rightParams, rightNext)

    def opSql(op: CompareOp): String = match op {
        case CompareOp.Eq => "="
        case CompareOp.Ne => "<>"
        case CompareOp.Lt => "<"
        case CompareOp.Le => "<="
        case CompareOp.Gt => ">"
        case CompareOp.Ge => ">="
        case CompareOp.Like => "LIKE"
    }

    ///
    /// 述語を、既にあるパラメータ列の後ろに繋ぐ。`$n` は続き番号。生成コードが slot を順に埋めるときに使う。
    ///
    pub def appendPred(pred: Pred[row], params: List[SqlValue]): (String, List[SqlValue]) =
        let (sql, added) = renderPred(pred, List.length(params) + 1);
        (sql, List.append(params, added))

    ///
    /// 並び順を `ORDER BY ...` に落とす。Unordered なら空文字。
    ///
    pub def renderOrder(order: Order[row]): String =
        match orderTerms(order) {
            case Nil => ""
            case terms => "ORDER BY " + List.join(", ", terms)
        }

    def orderTerms(order: Order[row]): List[String] = match order {
        case Order.Unordered => Nil
        case Order.Asc(col) => List#{"${col} ASC"}
        case Order.Desc(col) => List#{"${col} DESC"}
        case Order.Then(first, second) => List.append(orderTerms(first), orderTerms(second))
    }

}
