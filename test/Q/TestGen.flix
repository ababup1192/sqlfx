// Gen: examples/blog の生成物が今の生成器で作った物と一致する（make gen し忘れと生成器の版ずれの検知）。
// ライブラリ側のテストなのは、生成物の形を決めているのが Codegen だから。examples 側では確かめない。

/// examples/blog/src/Gen は migrations と .q から作り直した物と全ファイル一致する。
@Test
def testExampleGeneratedFilesAreUpToDate(): Unit \ {Assert, IO, Fs.DirList.DirList, Fs.FileRead.FileRead} =
    let stale = run {
        Gen.staleFiles({ migrations = "examples/blog/migrations", queries = "examples/blog/queries", out = "examples/blog/src/Gen", scopes = Nil })
    } with Fs.ReadFile.runWithFileRead;
    Assert.assertEq(expected = Ok(Nil), stale)

/// `--scope` の値: `列` は検査だけ、`列:effect` は注入。effect は名前空間付きでもよく、`:` の後ろが空なら検査だけ。
@Test
def testScopeSpec(): Unit \ Assert =
    Assert.assertEq(
        expected = List#{("project_id", None), ("project_id", Some("Tenant")), ("org_id", Some("Cms.Org")), ("project_id", None)},
        List.map(spec -> { let scope = scopeSpec(spec); (scope#column, scope#effect) }, List#{"project_id", "project_id:Tenant", "org_id:Cms.Org", "project_id:"}))
