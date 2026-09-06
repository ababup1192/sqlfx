///
/// 生 SQL の標識。生の SQL 文字列を DB に送る入口（`Sql.fetch` / `Sql.execute` / `Fragment.rawPred`）はこのエフェクトを要求する。
/// 使った関数の型に `RawSql` が付き、呼び出し元へ伝わるので、生 SQL に依存する箇所が型シグネチャから列挙できる。
/// 防止のための物ではなく、責任の所在を示す物。境界（main / テスト / 生成コード）が `runWithAllow` で許可する。
///
pub eff RawSql {
    def allow(sql: String): Unit
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
