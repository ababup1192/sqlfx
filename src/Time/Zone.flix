///
/// IANA のタイムゾーン。名前は `fromName` で 1 回だけ検証し、以後は値で持ち回る。
/// 「今どこの暦で見ているか」は `TimeZone` エフェクトで差し込む。
///
/// WhyNot: システム既定のゾーンを返す関数を置かないのは、実行環境のゾーンが黙って混ざる道を無くすため。
/// ゾーンは `TimeZone.runWith` を書いた所で必ず明示的に決まる。
///
mod Zone {

    import java.time.ZoneId
    import java.time.DateTimeException

    pub enum Zone(String) with Eq, Order, ToString

    pub def utc(): Zone = Zone.Zone("UTC")

    ///
    /// `"Asia/Tokyo"` のような IANA の名前から。無い名前は None。
    ///
    pub def fromName(name: String): Option[Zone] =
        Unsafe.runPure(() -> try {
            let _: ZoneId = ZoneId.of(name);
            Some(Zone.Zone(name))
        } catch {
            case _: DateTimeException => None
        })

    pub def toName(zone: Zone): String =
        let Zone.Zone(name) = zone;
        name

}
