// Pool: 開いただけのプールの数字（DB 無し。open は接続しない）。

/// 到達しない接続先。open は接続しに行かないので、数字を読むだけなら DB は要らない。
def unreachablePool(maxConnections: Int32): Pool.Pool \ IO =
    Pool.open({ maxConnections = maxConnections | Pool.defaultConfig({ url = "jdbc:postgresql://127.0.0.1:1/none", user = "none", password = "none" }) })

/// open 直後は active / idle / waiting / total が全部 0、max は設定値。
@Test
def testPoolStatsRightAfterOpen(): Unit \ {Assert, IO} =
    let pool = unreachablePool(7);
    let stats = Pool.stats(pool);
    Pool.close(pool);
    Assert.assertEq(expected = (0, 0, 0, 0, 7), (stats#active, stats#idle, stats#waiting, stats#total, stats#max))

/// 閉じた後も stats は例外を投げず、max は設定値のまま。
@Test
def testPoolStatsAfterClose(): Unit \ {Assert, IO} =
    let pool = unreachablePool(3);
    Pool.close(pool);
    let stats = Pool.stats(pool);
    Assert.assertEq(expected = (0, 0, 3), (stats#active, stats#total, stats#max))

/// 既定の設定は漏れの検出が無効（0）。
@Test
def testPoolDefaultConfigHasNoLeakDetection(): Unit \ Assert =
    let config = Pool.defaultConfig({ url = "jdbc:postgresql://127.0.0.1:1/none", user = "none", password = "none" });
    Assert.assertEq(expected = 0, config#leakDetectionThresholdMs)

/// 2000 未満の leakDetectionThresholdMs は 2000 に丸めて HikariCP に渡す（HikariCP が黙って無効にするのを防ぐ）。0 は無効のまま。
///
///   0    → 0
///   1    → 2000
///   1999 → 2000
///   2000 → 2000
///   5000 → 5000
@Test
def testPoolLeakDetectionThresholdIsRounded(): Unit \ {Assert, IO} =
    let config = Pool.defaultConfig({ url = "jdbc:postgresql://127.0.0.1:1/none", user = "none", password = "none" });
    let applied = List#{0, 1, 1999, 2000, 5000} |> List.map(threshold -> {
        let pool = Pool.open({ leakDetectionThresholdMs = threshold | config });
        let seen = Pool.leakDetectionThresholdMs(pool);
        Pool.close(pool);
        seen
    });
    Assert.assertEq(expected = List#{0, 2000, 2000, 2000, 5000}, applied)
