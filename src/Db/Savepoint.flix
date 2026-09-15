///
/// Tx の中の SAVEPOINT の境界。SAVEPOINT / RELEASE / ROLLBACK TO を発行する。
/// SqlRead / SqlWrite と同じく失敗は値で返し、`Tx.withSavepoint` が呼び出し側の文脈で op に変える。
/// 利用者は op を直接呼ばず、`Tx.withSavepoint` を使う。
///
/// WhyNot: `SqlWrite.execute` で流さないのは、読むだけ（`DbRead`）の Tx でも張れる物で、署名に `SqlWrite` が付くと
/// 読む関数が書く関数に見えるため。`SqlRead` に op を足さないのは、利用側の全 handler が壊れるため。
///
/// WhyNot: op を 3 つに分けないのは、Command に case を足したとき、素通しするだけの handler まで壊れるため（`DbErr` と同じ）。
///
pub eff SqlSavepoint {
    /// SAVEPOINT / RELEASE / ROLLBACK TO を 1 つ発行する
    def control(command: Savepoint.Command): Result[DbError.DbErrorKind, Unit]
}

mod Savepoint {

    ///
    /// 発行する文。名前は `isValidName` を通った物だけが入る。
    ///
    pub enum Command with Eq, Order, ToString {
        /// `SAVEPOINT name`
        case Savepoint(String)
        /// `RELEASE SAVEPOINT name`
        case Release(String)
        /// `ROLLBACK TO SAVEPOINT name`
        case RollbackTo(String)
    }

    ///
    /// 名前が `^[a-z_][a-z0-9_]*$` で 63 文字までか。SQL の文面に入る唯一の値なので、これ以外は通さない。
    ///
    /// WhyNot: 63 を超える名前を PG の切り詰めに任せないのは、切り詰めは NOTICE だけで失敗にならず、
    /// 入れ子の 2 つの名前が同じ名前に潰れて、内側の ROLLBACK TO が外側まで戻してしまうため。
    ///
    pub def isValidName(name: String): Bool =
        match String.toList(name) {
            case head :: rest => isLeading(head) and List.forAll(isFollowing, rest) and String.length(name) <= maxNameLength()
            case Nil          => false
        }

    ///
    /// 命令を SQL にする。
    ///
    pub def toSql(command: Command): String = match command {
        case Command.Savepoint(name)  => "SAVEPOINT ${name}"
        case Command.Release(name)    => "RELEASE SAVEPOINT ${name}"
        case Command.RollbackTo(name) => "ROLLBACK TO SAVEPOINT ${name}"
    }

    ///
    /// 名前の決まりを人が読む 1 行にする。断りの文言に使う。
    ///
    pub def nameRule(): String = "expected ^[a-z_][a-z0-9_]*$, at most ${maxNameLength()} chars"

    /// PG の識別子の上限（NAMEDATALEN - 1）。
    def maxNameLength(): Int32 = 63

    /// 先頭に置ける文字。ASCII の小文字と `_` だけ（`Char.isLetter` は ASCII 以外も通す）。
    def isLeading(ch: Char): Bool = (ch >= 'a' and ch <= 'z') or ch == '_'

    /// 2 文字目以降に置ける文字。
    def isFollowing(ch: Char): Bool = isLeading(ch) or (ch >= '0' and ch <= '9')

}
