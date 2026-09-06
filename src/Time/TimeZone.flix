///
/// 「今どこの暦で見ているか」。暦日の読み出しと表示はこれを要求するので、依存が関数の型に出る。
/// 境界（Web ならリクエストごと、CLI なら設定から 1 回）で `runWith` に渡す。テストは `TimeTest.runFrozen`。
///
pub eff TimeZone {
    def zone(): Zone.Zone
}

mod TimeZone {

    ///
    /// ゾーンを 1 つ決めて thunk を走らせる。
    ///
    pub def runWith(zone: Zone.Zone, thunk: Unit -> a \ ef): a \ ef - TimeZone =
        run {
            thunk()
        } with handler TimeZone {
            def zone(resume) = resume(zone)
        }

}
