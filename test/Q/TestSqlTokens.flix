///
/// SqlTokens: SQL 本文を語に切る字句。`/* */`（入れ子を数える）は語にしない、dollar quote（`$$…$$` / `$tag$…$tag$`）は 1 語。
///
mod TestSqlTokens {

    use Sqlfx.Q.SqlTokens

    ///
    /// 入力 → 語の並び。
    ///
    ///   SELECT id FROM entries /* project_id */ WHERE id = $1   → コメントの中の project_id は語にならない
    ///   SELECT 1 /* a /* b */ c */ + 2                          → 入れ子を数え、語は SELECT 1 + 2
    ///   SELECT id FROM t /* ( */ WHERE x = 1                    → コメントの中の ( で括弧の深さが崩れない
    ///   SELECT $$it's :x {y}$$ AS s                              → dollar quote は 1 語（中の ' で引用に入らない）
    ///   SELECT $tag$ a $$ b $tag$                                → 違う tag の $$ は中身
    ///   SELECT $1, $2                                            → $ + 数字は今のまま 1 語
    ///   SELECT 1 /* 閉じていない                                 → 閉じの無いコメントは最後まで
    ///
    @Test
    def testTokenizeCommentsAndDollarQuotes(): Unit \ Assert =
        let table = List#{
            ("SELECT id FROM entries /* project_id */ WHERE id = $1", List#{"SELECT", "id", "FROM", "entries", "WHERE", "id", "=", "$1"}),
            ("SELECT 1 /* a /* b */ c */ + 2", List#{"SELECT", "1", "+", "2"}),
            ("SELECT id FROM t /* ( */ WHERE x = 1", List#{"SELECT", "id", "FROM", "t", "WHERE", "x", "=", "1"}),
            ("SELECT $$it's :x {y}$$ AS s", List#{"SELECT", "$$it's :x {y}$$", "AS", "s"}),
            ("SELECT $tag$ a $$ b $tag$", List#{"SELECT", "$tag$ a $$ b $tag$"}),
            ("SELECT $1, $2", List#{"SELECT", "$1", ",", "$2"}),
            ("SELECT 1 /* x", List#{"SELECT", "1"})
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(SqlTokens.tokenize))

    ///
    /// NOT NULL の marker `!` を落とす時、dollar quote と `/* */` の中は触らない。
    ///
    ///   SELECT $$wow!$$, count(*)::bigint! AS n /* x! */  → SELECT $$wow!$$, count(*)::bigint AS n /* x! */
    ///
    @Test
    def testDropNotNullMarksKeepsQuotedText(): Unit \ Assert =
        Assert.assertEq(
            expected = "SELECT $$wow!$$, count(*)::bigint AS n /* x! */",
            SqlTokens.dropNotNullMarks("SELECT $$wow!$$, count(*)::bigint! AS n /* x! */"))

}
