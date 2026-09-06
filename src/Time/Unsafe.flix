///
/// Java の呼び出しを純粋な計算として扱う。java.time のように外の世界に触れない API にだけ使う。
///
/// WhyNot: 表示や parse に IO を付けないのは、ユースケース関数の型から「DB を読むだけ」「時刻に依存する」が
/// 読めなくなるから。ここで外した効果は型に出ないので、呼び先が本当に副作用を持たないことを呼ぶ側が保証する。
///
mod Unsafe {

    pub def runPure(f: Unit -> a \ IO): a = unchecked_cast(f() as _ \ {})

}
