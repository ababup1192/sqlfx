mod DbTest {

    use SqlValue.SqlValue
    use Row.Row
    use Row.Statement

    ///
    /// どの SELECT にも同じ rows を返す。ユースケース関数を DB 無しで走らせる最小のハンドラ。
    ///
    pub def runWithRows(rows: List[Row], thunk: Unit -> a \ ef): a \ ef - SqlRead =
        run {
            thunk()
        } with handler SqlRead {
            def fetch(_sql, _params, resume) = resume(rows)
        }

    ///
    /// SQL 文字列ごとに返す rows を変える。`table` が None を返した SQL は空の結果。
    ///
    pub def runWithTable(table: String -> Option[List[Row]], thunk: Unit -> a \ ef): a \ ef - SqlRead =
        run {
            thunk()
        } with handler SqlRead {
            def fetch(sql, _params, resume) = resume(table(sql) |> Option.getWithDefault(Nil))
        }

    ///
    /// 発行した Statement を順に記録して結果と一緒に返す。SELECT には rows、書き込みには affected を返す。
    /// クエリ数の上限テスト（層 3）と、発行 SQL の比較に使う。
    ///
    pub def runRecording(rows: List[Row], affected: Int32, thunk: Unit -> a \ ef): (a, List[Statement]) \ ef - {SqlRead, SqlWrite} =
        region rc {
            let log = Ref.fresh(rc, Nil);
            let record = statement -> Ref.put(statement :: Ref.get(log), log);
            let result = run {
                thunk()
            } with handler SqlRead {
                def fetch(sql, params, resume) = {
                    record({ sql = sql, params = params });
                    resume(rows)
                }
            } with handler SqlWrite {
                def execute(sql, params, resume) = {
                    record({ sql = sql, params = params });
                    resume(affected)
                }
            };
            (result, Ref.get(log) |> List.reverse)
        }

    ///
    /// Sql を包み、発行する文を Logger へ流してから外側の Sql へそのまま転送する。
    /// ハンドラを合成できることの見本。JDBC の前にも、runRecording の前にも被せられる。
    ///
    pub def runLogging(thunk: Unit -> a \ ef): a \ ef + {SqlRead, SqlWrite, Logger} =
        run {
            thunk()
        } with handler SqlRead {
            def fetch(sql, params, resume) = {
                Logger.debug("fetch ${sql} ${params}");
                resume(SqlRead.fetch(sql, params))
            }
        } with handler SqlWrite {
            def execute(sql, params, resume) = {
                Logger.debug("execute ${sql} ${params}");
                resume(SqlWrite.execute(sql, params))
            }
        }

}
