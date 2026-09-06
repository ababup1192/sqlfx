use SqlType.SqlType
use DdlParser.DdlError

// DdlParser: migrations の DDL から机上のスキーマを組む。

/// examples/blog と同じ形の DDL。
def blogDdl(): String =
    "-- users\n"
        + "CREATE TABLE users (\n"
        + "    id BIGSERIAL PRIMARY KEY,\n"
        + "    name TEXT NOT NULL,\n"
        + "    email TEXT UNIQUE,\n"
        + "    score NUMERIC(10, 2),\n"
        + "    legacy TEXT,\n"
        + "    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),\n"
        + "    CONSTRAINT users_name_len CHECK (length(name) > 0)\n"
        + ");\n"
        + "CREATE INDEX users_name_idx ON users (name);\n"
        + "ALTER TABLE users ADD COLUMN views INTEGER NOT NULL DEFAULT 0;\n"
        + "ALTER TABLE users DROP COLUMN legacy;\n"

/// 列の名前・型・NULL 可否。PRIMARY KEY と NOT NULL は非 NULL、NUMERIC(10, 2) は Decimal、ADD / DROP COLUMN が効く。
///
///   users: id Int64 | name Str | email Str? | score Decimal? | created_at Timestamp | views Int32
@Test
def testApplyBlogDdl(): Unit \ Assert =
    let columns = DdlParser.apply(blogDdl(), Schema.empty())
        |> Result.map(state -> {
            let (schema, warnings) = state;
            (Schema.findTable("users", schema) |> Option.map(table -> List.map(column -> (column#name, column#columnType, column#nullable), table#columns)), warnings)
        });
    Assert.assertEq(expected = Ok((Some(List#{
        ("id", Some(SqlType.Int64), false),
        ("name", Some(SqlType.Str), false),
        ("email", Some(SqlType.Str), true),
        ("score", Some(SqlType.Decimal), true),
        ("created_at", Some(SqlType.Timestamp), false),
        ("views", Some(SqlType.Int32), false)
    }), Nil)), columns)

/// 読めない DDL は警告になり、スキーマは進む。知らない型の列は型 None で登録される。
@Test
def testUnreadableDdlIsWarning(): Unit \ Assert =
    let result = DdlParser.apply("CREATE FUNCTION f() RETURNS void AS $$ $$ LANGUAGE sql; CREATE TABLE t (id BIGINT PRIMARY KEY, geo GEOMETRY)", Schema.empty())
        |> Result.map(state -> {
            let (schema, warnings) = state;
            (Schema.findTable("t", schema) |> Option.map(table -> List.map(column -> (column#name, column#columnType), table#columns)), warnings)
        });
    Assert.assertEq(expected = Ok((Some(List#{("id", Some(SqlType.Int64)), ("geo", None)}), List#{"unreadable DDL: CREATE FUNCTION f ..."})), result)

/// 無いテーブルへの ALTER と無い列の DROP はエラー。
@Test
def testAlterUnknownIsError(): Unit \ Assert =
    let errors = List#{
        "ALTER TABLE nope ADD COLUMN x INT",
        "CREATE TABLE t (id BIGINT); ALTER TABLE t DROP COLUMN nope"
    } |> List.map(sql -> DdlParser.apply(sql, Schema.empty()) |> Result.map(_ -> ()));
    Assert.assertEq(expected = List#{
        Err(DdlError.UnknownTable("ALTER TABLE nope ADD COLUMN x INT", "nope")),
        Err(DdlError.UnknownColumn("ALTER TABLE t DROP COLUMN nope", "nope"))
    }, errors)

/// ALTER TABLE の亜種。列の形（名前, 型, NULL 可否）の変化と、制約の追加は無視されること。
///
///   ADD x INT（COLUMN 省略）/ ADD COLUMN IF NOT EXISTS / DROP IF EXISTS / SET NOT NULL / DROP NOT NULL / TYPE / RENAME / ADD FOREIGN KEY
@Test
def testAlterVariants(): Unit \ Assert =
    let ddl = "CREATE TABLE t (id BIGINT PRIMARY KEY, a TEXT, b INT NOT NULL, c TEXT);"
        + "ALTER TABLE t ADD x INT;"
        + "ALTER TABLE t ADD COLUMN IF NOT EXISTS y VARCHAR(10) NOT NULL;"
        + "ALTER TABLE t DROP COLUMN IF EXISTS c;"
        + "ALTER TABLE t ALTER COLUMN a SET NOT NULL;"
        + "ALTER TABLE t ALTER COLUMN b DROP NOT NULL;"
        + "ALTER TABLE t ALTER COLUMN x TYPE BIGINT;"
        + "ALTER TABLE t RENAME COLUMN y TO z;"
        + "ALTER TABLE t ADD FOREIGN KEY (x) REFERENCES t(id);"
        + "ALTER TABLE ONLY t ADD CONSTRAINT t_a_key UNIQUE (a)";
    let result = DdlParser.apply(ddl, Schema.empty())
        |> Result.map(state -> {
            let (schema, warnings) = state;
            (Schema.findTable("t", schema) |> Option.map(table -> List.map(column -> (column#name, column#columnType, column#nullable), table#columns)), warnings)
        });
    Assert.assertEq(expected = Ok((Some(List#{
        ("id", Some(SqlType.Int64), false),
        ("a", Some(SqlType.Str), false),
        ("b", Some(SqlType.Int32), true),
        ("x", Some(SqlType.Int64), true),
        ("z", Some(SqlType.Str), false)
    }), Nil)), result)

/// DROP TABLE はカンマ区切りの全部を落とす。
@Test
def testDropTables(): Unit \ Assert =
    let result = DdlParser.apply("CREATE TABLE a (id INT); CREATE TABLE b (id INT); DROP TABLE IF EXISTS a, b CASCADE", Schema.empty())
        |> Result.map(state -> Map.size(fst(state)));
    Assert.assertEq(expected = Ok(0), result)
