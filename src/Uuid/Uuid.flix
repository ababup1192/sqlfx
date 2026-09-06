///
/// UUID。中身は 36 文字の文字列。Flix 側で ID を作って INSERT するときに使う。
///
mod Uuid {

    import java.util.{UUID => JavaUuid}
    import java.lang.IllegalArgumentException

    pub enum Uuid(String) with Eq, Order

    instance ToString[Uuid] {
        pub def toString(u: Uuid): String = Uuid.toText(u)
    }

    ///
    /// `"550e8400-e29b-41d4-a716-446655440000"` の形から。違えば None。小文字に揃える。
    ///
    pub def fromString(s: String): Option[Uuid] =
        Unsafe.runPure(() -> try {
            let parsed: JavaUuid = JavaUuid.fromString(s);
            Some(Uuid.Uuid(parsed.toString()))
        } catch {
            case _: IllegalArgumentException => None
        })

    pub def toText(u: Uuid): String =
        let Uuid.Uuid(s) = u;
        s

    ///
    /// ランダムな v4。
    ///
    pub def random(): Uuid \ NonDet =
        let generated: JavaUuid = unchecked_cast(JavaUuid.randomUUID() as _ \ NonDet);
        Uuid.Uuid(Unsafe.runPure(() -> generated.toString()))

}
