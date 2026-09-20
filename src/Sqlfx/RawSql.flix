pub mod Sqlfx.RawSql {

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
