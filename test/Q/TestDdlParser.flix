use SqlType.SqlType
use DdlParser.DdlError
use Schema.ConstraintKind

// DdlParser: migrations の DDL から机上のスキーマを組む。

/// examples/blog と同じ形の DDL。
def blogDdl(): String =
    "-- users\n"
        + "CREATE TABLE users (\n"
        + "    id BIGSERIAL PRIMARY KEY,\n"
        + "    name TEXT NOT NULL,\n"
        + "    email TEXT CONSTRAINT users_email_key UNIQUE,\n"
        + "    score NUMERIC(10, 2),\n"
        + "    legacy TEXT,\n"
        + "    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),\n"
        + "    CONSTRAINT users_name_len CHECK (length(name) > 0)\n"
        + ");\n"
        + "CREATE INDEX users_name_idx ON users (name);\n"
        + "ALTER TABLE users ADD COLUMN views INTEGER NOT NULL DEFAULT 0;\n"
        + "ALTER TABLE users DROP COLUMN legacy;\n"

/// 列の名前・型・NULL 可否。PRIMARY KEY と NOT NULL は非 NULL、NUMERIC(10, 2) は Decimal、ADD / DROP COLUMN が効く。
/// 名前付きの制約は列の中（CONSTRAINT ... UNIQUE）でもテーブル制約でも拾う。
///
///   users: id Int64 | name Str | email Str? | score Decimal? | created_at Timestamp | views Int32
///   constraints: users_email_key unique, users_name_len check
@Test
def testApplyBlogDdl(): Unit \ Assert =
    let columns = DdlParser.apply(blogDdl(), Schema.empty())
        |> Result.map(state -> {
            let (schema, warnings) = state;
            let table = Schema.findTable("users", schema);
            (table |> Option.map(t -> List.map(column -> (column#name, column#columnType, column#nullable), t#columns)),
             table |> Option.map(t -> List.map(c -> (c#name, c#kind), t#constraints)),
             warnings)
        });
    Assert.assertEq(expected = Ok((Some(List#{
        ("id", Some(SqlType.Int64), false),
        ("name", Some(SqlType.Str), false),
        ("email", Some(SqlType.Str), true),
        ("score", Some(SqlType.Decimal), true),
        ("created_at", Some(SqlType.Timestamp), false),
        ("views", Some(SqlType.Int32), false)
    }), Some(List#{("users_email_key", ConstraintKind.Unique), ("users_name_len", ConstraintKind.Check)}), Nil)), columns)

/// 名前の無い UNIQUE / CHECK / FOREIGN KEY はエラー。列の中でもテーブル制約でも ALTER でも。
/// 列に名前付きの制約があっても、その隣の名前無し REFERENCES は見逃さない。PRIMARY KEY は名前無しでも名前付きでもよい。
@Test
def testUnnamedConstraintIsError(): Unit \ Assert =
    let errors = List#{
        DdlParser.apply("CREATE TABLE t (id BIGINT PRIMARY KEY, email TEXT UNIQUE)", Schema.empty()) |> Result.map(_ -> ()),
        DdlParser.apply("CREATE TABLE t (id BIGINT PRIMARY KEY, CHECK (id > 0))", Schema.empty()) |> Result.map(_ -> ()),
        DdlParser.apply("CREATE TABLE t (id BIGINT PRIMARY KEY); ALTER TABLE t ADD FOREIGN KEY (id) REFERENCES t(id)", Schema.empty()) |> Result.map(_ -> ()),
        DdlParser.apply("CREATE TABLE t (id BIGINT, uid BIGINT REFERENCES t(id) CONSTRAINT t_uid_pos CHECK (uid > 0))", Schema.empty()) |> Result.map(_ -> ()),
        DdlParser.apply("CREATE TABLE t (id BIGINT, PRIMARY KEY (id))", Schema.empty()) |> Result.map(_ -> ()),
        DdlParser.apply("CREATE TABLE t (id BIGINT CONSTRAINT t_pkey PRIMARY KEY, name TEXT CONSTRAINT t_name_nn NOT NULL)", Schema.empty()) |> Result.map(_ -> ())
    };
    Assert.assertEq(expected = List#{
        Err(DdlError.UnnamedColumnConstraint("CREATE TABLE t (id BIGINT PRIMARY KEY, email TEXT UNIQUE)", "email")),
        Err(DdlError.UnnamedTableConstraint("CREATE TABLE t (id BIGINT PRIMARY KEY, CHECK (id > 0))", "t")),
        Err(DdlError.UnnamedTableConstraint("ALTER TABLE t ADD FOREIGN KEY (id) REFERENCES t(id)", "t")),
        Err(DdlError.UnnamedColumnConstraint("CREATE TABLE t (id BIGINT, uid BIGINT REFERENCES t(id) CONSTRAINT t_uid_pos CHECK (uid > 0))", "uid")),
        Ok(()),
        Ok(())
    }, errors)

/// 1 列に名前付きの制約が 2 つあれば両方拾う。CHECK の式の中の語は制約として読まない。
@Test
def testTwoConstraintsOnOneColumn(): Unit \ Assert =
    let result = DdlParser.apply("CREATE TABLE t (a TEXT CONSTRAINT t_a_key UNIQUE CONSTRAINT t_a_chk CHECK (a <> 'unique'))", Schema.empty())
        |> Result.map(state -> Schema.findTable("t", fst(state)) |> Option.map(t -> List.map(c -> (c#name, c#kind), t#constraints)));
    Assert.assertEq(expected = Ok(Some(List#{("t_a_key", ConstraintKind.Unique), ("t_a_chk", ConstraintKind.Check)})), result)

/// 引用符の無い識別子は小文字に畳む（PG と同じ）。引用符付きはそのまま。
///
///   CONSTRAINT Users_Email_Key → users_email_key / CONSTRAINT "Mixed_Case" → Mixed_Case / TABLE Users → users
@Test
def testUnquotedIdentifiersFoldToLowerCase(): Unit \ Assert =
    let result = DdlParser.apply("CREATE TABLE Users (id BIGINT, CONSTRAINT Users_Email_Key UNIQUE (id), CONSTRAINT \"Mixed_Case\" CHECK (id > 0))", Schema.empty())
        |> Result.map(state -> Schema.findTable("users", fst(state)) |> Option.map(t -> List.map(c -> c#name, t#constraints)));
    Assert.assertEq(expected = Ok(Some(List#{"users_email_key", "Mixed_Case"})), result)

/// RENAME CONSTRAINT / ALTER INDEX RENAME / DROP INDEX a, b が制約の一覧に効く。複数アクションの ALTER TABLE は警告。
///
///   t_a_key → t_a_uniq（RENAME CONSTRAINT）、t_b_idx → t_b_uniq（ALTER INDEX）、DROP INDEX t_b_uniq, t_c_idx → [t_a_uniq]
@Test
def testConstraintRenamesAndMultiDrop(): Unit \ Assert =
    let ddl = "CREATE TABLE t (id BIGINT PRIMARY KEY, a TEXT, b TEXT, c TEXT);"
        + "ALTER TABLE t ADD CONSTRAINT t_a_key UNIQUE (a);"
        + "CREATE UNIQUE INDEX t_b_idx ON t (b);"
        + "CREATE UNIQUE INDEX t_c_idx ON t (c);"
        + "ALTER TABLE t RENAME CONSTRAINT t_a_key TO t_a_uniq;"
        + "ALTER INDEX t_b_idx RENAME TO t_b_uniq;"
        + "DROP INDEX IF EXISTS t_b_uniq, t_c_idx;"
        + "ALTER TABLE t ADD COLUMN x INT, ADD COLUMN y INT";
    let result = DdlParser.apply(ddl, Schema.empty())
        |> Result.map(state -> (Schema.findTable("t", fst(state)) |> Option.map(t -> List.map(c -> c#name, t#constraints)), List.length(snd(state))));
    Assert.assertEq(expected = Ok((Some(List#{"t_a_uniq"}), 1)), result)

/// ADD CONSTRAINT / DROP CONSTRAINT / CREATE UNIQUE INDEX / DROP INDEX が制約の一覧を進める。同名は差し替え。
///
///   add t_a_key, add t_b_check, unique index t_c_idx, drop t_a_key, drop index t_c_idx → [t_b_check]
@Test
def testConstraintLifecycle(): Unit \ Assert =
    let ddl = "CREATE TABLE t (id BIGINT PRIMARY KEY, a TEXT, b INT, c TEXT);"
        + "ALTER TABLE t ADD CONSTRAINT t_a_key UNIQUE (a);"
        + "ALTER TABLE t ADD CONSTRAINT t_b_check CHECK (b > 0);"
        + "CREATE UNIQUE INDEX IF NOT EXISTS t_c_idx ON t (c);"
        + "ALTER TABLE t DROP CONSTRAINT IF EXISTS t_a_key;"
        + "DROP INDEX t_c_idx";
    let result = DdlParser.apply(ddl, Schema.empty())
        |> Result.map(state -> Schema.findTable("t", fst(state)) |> Option.map(t -> List.map(c -> (c#name, c#kind), t#constraints)));
    Assert.assertEq(expected = Ok(Some(List#{("t_b_check", ConstraintKind.Check)})), result)

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

/// ALTER TABLE の亜種。列の形（名前, 型, NULL 可否）の変化。制約の追加は列に影響しないこと。
///
///   ADD x INT（COLUMN 省略）/ ADD COLUMN IF NOT EXISTS / DROP IF EXISTS / SET NOT NULL / DROP NOT NULL / TYPE / RENAME / ADD CONSTRAINT
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
        + "ALTER TABLE t ADD CONSTRAINT t_x_fkey FOREIGN KEY (x) REFERENCES t(id);"
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
