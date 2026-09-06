///
/// 断片 DSL（design.md §5）。`.q` の `{slot}` に入れる述語と並び順を、型付きの値として組む。
/// 値は必ずプレースホルダになり、識別子は Col を通した物しか出ないので、SQL インジェクションが構造的に起きない。
///
///
/// 生 SQL を断片に入れるエスケープハッチの標識。使う箇所が型から列挙できる。
///
pub eff RawSql {
    def allow(sql: String): Unit
}

mod Fragment {

    // 利用者が呼ぶのは組み立ての関数（eq ... all / asc desc then）。render 系は生成コードが呼ぶ。
    // and / or / not は Flix の予約語なので both / either / negate と名付けている。

    use SqlValue.SqlValue

    ///
    /// テーブル `row` の型 `a` の列。生成器が吐く。第 2 引数は値を SqlValue に包む関数。
    ///
    pub enum Col[_row: Type, a: Type] {
        case Col(String, a -> SqlValue)
    }

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

    def colName(col: Col[row, a]): String = match col { case Col.Col(name, _) => name }

    def encode(col: Col[row, a], value: a): SqlValue = match col { case Col.Col(_, toSql) => toSql(value) }

    pub def eq(col: Col[row, a], value: a): Pred[row] = Pred.Compare(colName(col), CompareOp.Eq, encode(col, value))
    pub def ne(col: Col[row, a], value: a): Pred[row] = Pred.Compare(colName(col), CompareOp.Ne, encode(col, value))
    pub def lt(col: Col[row, a], value: a): Pred[row] = Pred.Compare(colName(col), CompareOp.Lt, encode(col, value))
    pub def le(col: Col[row, a], value: a): Pred[row] = Pred.Compare(colName(col), CompareOp.Le, encode(col, value))
    pub def gt(col: Col[row, a], value: a): Pred[row] = Pred.Compare(colName(col), CompareOp.Gt, encode(col, value))
    pub def ge(col: Col[row, a], value: a): Pred[row] = Pred.Compare(colName(col), CompareOp.Ge, encode(col, value))
    pub def like(col: Col[row, String], pattern: String): Pred[row] = Pred.Compare(colName(col), CompareOp.Like, SqlValue.Str(pattern))
    pub def isNull(col: Col[row, a]): Pred[row] = Pred.IsNull(colName(col))
    pub def isNotNull(col: Col[row, a]): Pred[row] = Pred.IsNotNull(colName(col))
    pub def inList(col: Col[row, a], values: List[a]): Pred[row] = Pred.In(colName(col), List.map(encode(col), values))
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

    pub def asc(col: Col[row, a]): Order[row] = Order.Asc(colName(col))
    pub def desc(col: Col[row, a]): Order[row] = Order.Desc(colName(col))
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

mod RawSql {

    ///
    /// 生 SQL を全部許す。監査した上で main などの境界で被せる。
    ///
    pub def runWithAllow(thunk: Unit -> a \ ef): a \ ef - RawSql =
        run {
            thunk()
        } with handler RawSql {
            def allow(_sql, resume) = resume(())
        }

}
