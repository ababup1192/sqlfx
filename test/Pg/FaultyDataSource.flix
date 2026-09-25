///
/// 決まった所で失敗する DataSource（fatal の後始末のテスト用）。本物の PG の接続を `java.lang.reflect.Proxy` で包んで HikariCP に渡す。
///
/// SQL に marker を書いた文と、設定の旗で、失敗する所を選ぶ:
///
///   `/* inject: fatal-on-prepare */`             prepareStatement で OutOfMemoryError
///   `/* inject: fatal-after-execute */`          本物の execute を走らせた後で OutOfMemoryError
///   `/* inject: driver-runtime-after-execute */` 同じ所で、stack trace の先頭が pgjdbc の frame の IllegalStateException
///   `/* inject: runtime-after-execute */`        同じ所で素の IllegalStateException
///   failSetAutoCommit                             setAutoCommit(false) で SQLException
///   failRollback                                  rollback() で SQLException
///   fatalOnCommit                                 commit() で OutOfMemoryError
///
/// 本物の接続への呼び出し（setAutoCommit / commit / rollback / clearWarnings / execute / close）を
/// 「物理接続の番号:名前」で `calls` に記録する。evict の後に protocol の呼び出しが無い事を見るため。
///
mod FaultyDataSource {

    use Sqlfx.Pool

    import com.zaxxer.hikari.HikariConfig
    import com.zaxxer.hikari.HikariDataSource
    import java.io.PrintWriter
    import java.lang.Class
    import java.lang.ClassLoader
    import java.lang.IllegalStateException
    import java.lang.Object
    import java.lang.OutOfMemoryError
    import java.lang.StackTraceElement
    import java.lang.Throwable
    import java.lang.reflect.InvocationHandler
    import java.lang.reflect.InvocationTargetException
    import java.lang.reflect.Method
    import java.lang.reflect.Proxy
    import java.sql.Connection
    import java.sql.SQLException
    import java.util.Objects
    import java.util.logging.Logger
    import javax.sql.DataSource
    import org.postgresql.ds.PGSimpleDataSource

    ///
    /// 失敗させる所の旗。
    ///
    /// - `failSetAutoCommit`: `setAutoCommit(false)`（BEGIN）で SQLException
    /// - `failRollback`: `rollback()` で SQLException
    /// - `fatalOnCommit`: `commit()` で OutOfMemoryError
    ///
    pub type alias Faults = { failSetAutoCommit = Bool, failRollback = Bool, fatalOnCommit = Bool }

    ///
    /// 何も失敗させない旗。
    ///
    pub def noFaults(): Faults = { failSetAutoCommit = false, failRollback = false, fatalOnCommit = false }

    ///
    /// 組んだプールと、本物の接続への呼び出しの記録（新しい物が先頭）。
    ///
    pub type alias Faulty = { pool = Pool.Pool, calls = Ref[List[String], Static] }

    ///
    /// 大きさ 1・借り待ち 300 ms のプールを、失敗する DataSource で組む。
    ///
    pub def open(faults: Faults): Faulty \ IO =
        let calls = Ref.fresh(Static, Nil);
        let opened = Ref.fresh(Static, 0);
        let hikari = new HikariConfig();
        hikari.setDataSource(dataSource(faults, calls, opened));
        hikari.setMaximumPoolSize(1);
        hikari.setConnectionTimeout(300i64);
        hikari.setInitializationFailTimeout(-1i64);
        { pool = Pool.Pool(new HikariDataSource(hikari)), calls = calls }

    ///
    /// 記録を古い順に。
    ///
    pub def callsOf(faulty: Faulty): List[String] \ IO =
        Ref.get(faulty#calls) |> List.reverse

    ///
    /// 物理接続 `index` への、記録の `after` 番目より後の protocol の呼び出し（ROLLBACK / setAutoCommit / clearWarnings / commit）の数。
    ///
    pub def protocolCallsAfter(after: Int32, index: Int32, faulty: Faulty): Int32 \ IO =
        callsOf(faulty)
            |> List.drop(after)
            |> List.filter(call -> List.exists(name -> call == "c${index}:${name}", List#{"rollback", "setAutoCommit(true)", "setAutoCommit(false)", "clearWarnings", "commit"}))
            |> List.length

    ///
    /// 本物の PGSimpleDataSource を包む DataSource。getConnection のたびに物理接続の番号を 1 つ進める。
    ///
    def dataSource(faults: Faults, calls: Ref[List[String], Static], opened: Ref[Int32, Static]): DataSource \ IO =
        let real = realDataSource();
        new DataSource {
            def getConnection(_this: DataSource): Connection \ IO =
                let conn = real.getConnection();
                Ref.put(Ref.get(opened) + 1, opened);
                connectionProxy(faults, calls, Ref.get(opened), conn)
            def getConnection(_this: DataSource, user: String, password: String): Connection \ IO =
                let conn = real.getConnection(user, password);
                Ref.put(Ref.get(opened) + 1, opened);
                connectionProxy(faults, calls, Ref.get(opened), conn)
            def getLogWriter(_this: DataSource): PrintWriter \ IO = real.getLogWriter()
            def setLogWriter(_this: DataSource, writer: PrintWriter): Unit \ IO = real.setLogWriter(writer)
            def setLoginTimeout(_this: DataSource, seconds: Int32): Unit \ IO = real.setLoginTimeout(seconds)
            def getLoginTimeout(_this: DataSource): Int32 \ IO = real.getLoginTimeout()
            def getParentLogger(_this: DataSource): Logger \ IO = real.getParentLogger()
            def unwrap(_this: DataSource, target: Class[Object]): Object \ IO = { let found: Object = real.unwrap(target); found }
            def isWrapperFor(_this: DataSource, target: Class[Object]): Bool \ IO = { let found: Bool = real.isWrapperFor(target); found }
        }

    ///
    /// テストの PG への本物の DataSource。
    ///
    def realDataSource(): PGSimpleDataSource \ IO =
        let config = pgConfig();
        let source = new PGSimpleDataSource();
        source.setUrl(config#url);
        source.setUser(config#user);
        source.setPassword(config#password);
        source

    ///
    /// 本物の接続を包む Proxy。
    ///
    def connectionProxy(faults: Faults, calls: Ref[List[String], Static], index: Int32, real: Connection): Connection \ IO =
        let onCall = new InvocationHandler {
            def invoke(_this: InvocationHandler, _proxy: Object, method: Method, args: Array[Object, Static]): Object \ IO =
                let name: String = method.getName();
                if (name == "prepareStatement") {
                    let sql: String = unchecked_cast(Array.get(0, args) as String);
                    if (String.contains(substr = "inject: fatal-on-prepare", sql)) throw new OutOfMemoryError("injected on prepare")
                    else {
                        let target: Object = checked_cast(real);
                        let statement = delegate(method, target, args);
                        statementProxy(calls, index, sql, statement)
                    }
                } else {
                    record(calls, index, callName(name, args));
                    if (name == "setAutoCommit" and faults#failSetAutoCommit and isFalse(args)) throw new SQLException("injected setAutoCommit failure")
                    else if (name == "rollback" and faults#failRollback and isNoArgs(args)) throw new SQLException("injected rollback failure")
                    else if (name == "commit" and faults#fatalOnCommit) throw new OutOfMemoryError("injected on commit")
                    else {
                        let target: Object = checked_cast(real);
                        delegate(method, target, args)
                    }
                }
        };
        unchecked_cast(proxyOf("java.sql.Connection", onCall) as Connection)

    ///
    /// PreparedStatement を包む Proxy。execute の後で marker の失敗を起こす。
    ///
    def statementProxy(calls: Ref[List[String], Static], index: Int32, sql: String, real: Object): Object \ IO =
        let onCall = new InvocationHandler {
            def invoke(_this: InvocationHandler, _proxy: Object, method: Method, args: Array[Object, Static]): Object \ IO =
                let name: String = method.getName();
                let result = delegate(method, real, args);
                if (String.startsWith(prefix = "execute", name)) {
                    record(calls, index, "execute");
                    if (String.contains(substr = "inject: fatal-after-execute", sql)) throw new OutOfMemoryError("injected after execute")
                    else if (String.contains(substr = "inject: driver-runtime-after-execute", sql)) throw driverRuntime()
                    else if (String.contains(substr = "inject: runtime-after-execute", sql)) throw new IllegalStateException("injected runtime after execute")
                    else result
                } else result
        };
        proxyOf("java.sql.PreparedStatement", onCall)

    ///
    /// stack trace の先頭を pgjdbc の frame にした IllegalStateException（pgjdbc の中から出た物の形）。
    ///
    def driverRuntime(): IllegalStateException \ IO =
        let error = new IllegalStateException("injected driver runtime after execute");
        let frame = new StackTraceElement("org.postgresql.core.v3.QueryExecutorImpl", "execute", "QueryExecutorImpl.java", 1);
        let frames: Array[StackTraceElement, Static] = Array#{frame} @ Static;
        error.setStackTrace(frames);
        error

    ///
    /// 本物へ呼び出しを渡す。本物が投げた物は InvocationTargetException から出して投げ直す。
    ///
    def delegate(method: Method, target: Object, args: Array[Object, Static]): Object \ IO =
        try {
            method.invoke(target, args)
        } catch {
            case e: InvocationTargetException =>
                let cause: Throwable = e.getCause();
                throw cause
        }

    ///
    /// interface の名前と handler から Proxy を作る。
    ///
    def proxyOf(interfaceName: String, onCall: InvocationHandler): Object \ IO =
        let target: Class[Object] = Class.forName(interfaceName);
        let loader: ClassLoader = target.getClassLoader();
        let interfaces: Array[Class[Object], Static] = Array#{target} @ Static;
        Proxy.newProxyInstance(loader, interfaces, onCall)

    ///
    /// 記録に 1 つ足す。
    ///
    def record(calls: Ref[List[String], Static], index: Int32, name: String): Unit \ IO =
        Ref.put("c${index}:${name}" :: Ref.get(calls), calls)

    ///
    /// 記録に使う呼び出しの名前。setAutoCommit だけ引数を付ける。
    ///
    def callName(name: String, args: Array[Object, Static]): String \ IO =
        if (name == "setAutoCommit") (if (isFalse(args)) "setAutoCommit(false)" else "setAutoCommit(true)") else name

    ///
    /// 引数が 1 つで false か。
    ///
    def isFalse(args: Array[Object, Static]): Bool \ IO =
        if (isNoArgs(args)) false
        else {
            let first: Object = Array.get(0, args);
            let text: String = first.toString();
            text == "false"
        }

    ///
    /// 引数が無いか（Proxy は引数の無い呼び出しに null を渡す）。
    ///
    def isNoArgs(args: Array[Object, Static]): Bool =
        Objects.isNull(unchecked_cast(args as Object)) or Array.length(args) == 0

}
