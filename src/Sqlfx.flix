///
/// sqlfx が公開するエフェクトと、その集合の型エイリアス。
///
/// WhyNot: エフェクトを各モジュールのファイルに残さないのは、Flix が 1 つのモジュールを複数のファイルに
/// 分けて書けず（reopening できない）、`Sqlfx` 直下の宣言を 1 ファイルに集めるしかないため。
///
pub mod Sqlfx {

    use Sqlfx.DbError
    use Sqlfx.Row
    use Sqlfx.Savepoint
    use Sqlfx.SqlValue
    use Sqlfx.Zone

    ///
    /// DB から読む境界。SELECT だけを発行する。
    /// op の戻りが Result なのは、ハンドラ本体で投げたエフェクトは呼び出し側の内側のハンドラには届かないから
    /// （Flix のハンドラ本体は `run` の外側で評価される）。失敗は値で返し、`Sql.fetch` が呼び出し側の文脈で op に変える。
    /// こうしておくと、アプリは `DbError.runWithKind` を自分の呼び出しの周りに被せて制約違反を拾える。
    ///
    pub eff SqlRead {
        /// SQL とプレースホルダの値を渡し、結果セットを全部 materialize して返す
        def fetch(sql: String, params: List[SqlValue.SqlValue]): Result[DbError.DbErrorKind, List[Row.Row]]
    }

    ///
    /// DB へ書く境界。INSERT / UPDATE / DELETE を発行する。
    ///
    pub eff SqlWrite {
        /// SQL とプレースホルダの値を渡し、影響行数を返す
        def execute(sql: String, params: List[SqlValue.SqlValue]): Result[DbError.DbErrorKind, Int32]
        /// `INSERT ... RETURNING` のように書いた上で行も返す文。結果セットを全部 materialize して返す
        def executeReturning(sql: String, params: List[SqlValue.SqlValue]): Result[DbError.DbErrorKind, List[Row.Row]]
    }

    ///
    /// 読む関数の効果。ハンドラが返した失敗は呼び出し側で op になる。
    /// 生の SQL 文字列を渡す `Sql.*` にはさらに `RawSql` が付く。`.q` から生成した関数には付かない。
    ///
    pub type alias DbRead = {SqlRead, TransientDbErr, DbErr}

    ///
    /// 書く関数の効果。
    ///
    pub type alias DbWrite = {SqlWrite, TransientDbErr, DbErr}

    ///
    /// 一時障害。Tx 境界ごと再実行すれば回復しうる。インフラ層の withRetry で捌く。
    /// op は 1 つで、種類は `DbErrorKind` の値で渡す（`isTransient` が true の case だけを渡す約束）。
    /// 投げるのは `TransientDbErr.deadlock()` のような関数（`mod TransientDbErr`）。
    ///
    /// WhyNot: 種類ごとに op を分けないのは、case を 1 つ足すたびに「素通しするだけ」の handler まで含めて
    /// 利用側の全 handler がコンパイルエラーになるため。壊れる範囲を「網羅 match を書いた所」だけに縮める。
    ///
    pub eff TransientDbErr {
        def raise(kind: DbError.DbErrorKind): Void
    }

    ///
    /// 再実行しても直らない DB エラー。制約違反はアプリが分岐したければハンドラで拾い、それ以外は main でログを出して終了する。
    /// op は 1 つで、種類は `DbErrorKind` の値で渡す（`isTransient` が false の case だけを渡す約束）。
    /// 投げるのは `DbErr.uniqueViolation(constraint)` のような関数（`mod DbErr`）。
    ///
    pub eff DbErr {
        def raise(kind: DbError.DbErrorKind): Void
    }

    ///
    /// エフェクト集合をまとめて書くための alias。ハンドラは個別に被せる。
    ///
    pub type alias Db = {SqlRead, SqlWrite, TransientDbErr, DbErr}

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

    ///
    /// 生 SQL の標識。生の SQL 文字列を DB に送る入口（`Sql.fetch` / `Sql.execute` / `Fragment.rawPred`）はこのエフェクトを要求する。
    /// 使った関数の型に `RawSql` が付き、呼び出し元へ伝わるので、生 SQL に依存する箇所が型シグネチャから列挙できる。
    /// 防止のための物ではなく、責任の所在を示す物。境界（main / テスト / 生成コード）が `runWithAllow` で許可する。
    ///
    pub eff RawSql {
        def allow(sql: String): Unit
    }

    ///
    /// 「今どこの暦で見ているか」。暦日の読み出しと表示はこれを要求するので、依存が関数の型に出る。
    /// 境界（Web ならリクエストごと、CLI なら設定から 1 回）で `runWith` に渡す。テストは `TimeTest.runFrozen`。
    ///
    pub eff TimeZone {
        def zone(): Zone.Zone
    }

}
