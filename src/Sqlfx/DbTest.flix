///
/// DB 無しのテスト用の handler。どれも thunk の中で投げた JVM の例外を `run` の直下で拾い、`run` を抜けてから同じ物を投げ直す
/// （`Db.rethrowing`。catch を直下に持たない `run` を利用側の経路に置かないため）。
///
pub mod Sqlfx.DbTest {

    use Sqlfx.Db
    use Sqlfx.DbError
    use Sqlfx.Row
    use Sqlfx.Savepoint
    use Sqlfx.SqlRead
    use Sqlfx.SqlSavepoint
    use Sqlfx.SqlWrite

    use Sqlfx.SqlValue.SqlValue
    use Sqlfx.Row.Row
    use Sqlfx.Row.Statement

    ///
    /// どの SELECT にも同じ rows を返す。ユースケース関数を DB 無しで走らせる最小のハンドラ。
    /// SAVEPOINT の命令（`Tx.withSavepoint`）は全部通す。
    ///
    pub def runWithRows(rows: List[Row], thunk: Unit -> a \ ef): a \ ef - {SqlRead, SqlSavepoint} =
        let outcome = run {
            Db.catchAll(thunk)
        } with handler SqlRead {
            def fetch(_sql, _params, resume) = resume(Ok(rows))
        } with handler SqlSavepoint {
            def control(_command, resume) = resume(Ok(()))
        };
        Db.rethrowing(outcome)

    ///
    /// SQL 文字列ごとに返す rows を変える。`rowsFor` が None を返した SQL は空の結果。
    ///
    pub def runWithTable(rowsFor: String -> Option[List[Row]], thunk: Unit -> a \ ef): a \ ef - {SqlRead, SqlSavepoint} =
        let outcome = run {
            Db.catchAll(thunk)
        } with handler SqlRead {
            def fetch(sql, _params, resume) = resume(Ok(rowsFor(sql) |> Option.getWithDefault(Nil)))
        } with handler SqlSavepoint {
            def control(_command, resume) = resume(Ok(()))
        };
        Db.rethrowing(outcome)

    ///
    /// 発行した Statement を順に記録して結果と一緒に返す。SELECT には rows、書き込みには affected を返す。
    /// SAVEPOINT の命令（`Tx.withSavepoint`）も `SAVEPOINT name` のような文として記録する（params は Nil）。
    /// クエリ数の上限テスト（層 3）と、発行 SQL の比較に使う。
    ///
    pub def runRecording(rows: List[Row], affected: Int32, thunk: Unit -> a \ ef): (a, List[Statement]) \ ef - {SqlRead, SqlWrite, SqlSavepoint} =
        runRecordingWith(_ -> Some(rows), affected, thunk)

    ///
    /// runRecording と同じく記録しつつ、SELECT に返す rows は SQL 文字列ごとに変える（runWithTable と同じ引数）。
    /// preload のように「複数の SELECT を出し、その数を確かめたい」テストに使う。
    ///
    pub def runRecordingWith(rowsFor: String -> Option[List[Row]], affected: Int32, thunk: Unit -> a \ ef): (a, List[Statement]) \ ef - {SqlRead, SqlWrite, SqlSavepoint} =
        region rc {
            let log = Ref.fresh(rc, Nil);
            let record = statement -> Ref.put(statement :: Ref.get(log), log);
            let outcome = run {
                Db.catchAll(thunk)
            } with handler SqlRead {
                def fetch(sql, params, resume) = {
                    record({ sql = sql, params = params });
                    resume(Ok(rowsFor(sql) |> Option.getWithDefault(Nil)))
                }
            } with handler SqlWrite {
                def execute(sql, params, resume) = {
                    record({ sql = sql, params = params });
                    resume(Ok(affected))
                }
                def executeReturning(sql, params, resume) = {
                    record({ sql = sql, params = params });
                    resume(Ok(rowsFor(sql) |> Option.getWithDefault(Nil)))
                }
            } with handler SqlSavepoint {
                def control(command, resume) = {
                    record({ sql = Savepoint.toSql(command), params = Nil });
                    resume(Ok(()))
                }
            };
            let result = Db.rethrowing(outcome);
            (result, Ref.get(log) |> List.reverse)
        }

    ///
    /// 書き込みが全部 `kind` で失敗する。execute と executeReturning の両方。
    /// 制約違反の翻訳（uniqueViolation → 業務エラー等）を DB 無しで確かめるのに使う。
    ///
    pub def runFailingWrite(kind: DbError.DbErrorKind, thunk: Unit -> a \ ef): a \ ef - SqlWrite =
        let outcome = run {
            Db.catchAll(thunk)
        } with handler SqlWrite {
            def execute(_sql, _params, resume) = resume(Err(kind))
            def executeReturning(_sql, _params, resume) = resume(Err(kind))
        };
        Db.rethrowing(outcome)

    ///
    /// Sql を包み、発行する文を Logger へ流してから外側の Sql へそのまま転送する。
    /// ハンドラを合成できることの見本。JDBC の前にも、runRecording の前にも被せられる。
    /// WhyNot: パラメータの値をログに出さないのは、password や個人情報が平文で残るから。SQL と件数だけ出す。
    ///
    pub def runLogging(thunk: Unit -> a \ ef): a \ ef + {SqlRead, SqlWrite, Logger} =
        let outcome = run {
            Db.catchAll(thunk)
        } with handler SqlRead {
            def fetch(sql, params, resume) = {
                Logger.debug("fetch ${sql} (${List.length(params)} params)");
                resume(SqlRead.fetch(sql, params))
            }
        } with handler SqlWrite {
            def execute(sql, params, resume) = {
                Logger.debug("execute ${sql} (${List.length(params)} params)");
                resume(SqlWrite.execute(sql, params))
            }
            def executeReturning(sql, params, resume) = {
                Logger.debug("executeReturning ${sql} (${List.length(params)} params)");
                resume(SqlWrite.executeReturning(sql, params))
            }
        };
        Db.rethrowing(outcome)

}
