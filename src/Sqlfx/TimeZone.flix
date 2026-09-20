pub mod Sqlfx.TimeZone {

    use Sqlfx.Zone

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
