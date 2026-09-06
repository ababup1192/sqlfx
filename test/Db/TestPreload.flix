// Preload: 親と子をキーで束ねる（DB 無し）。

/// 子は親の順に付き、同じ親の子は元の順、子の無い親は Nil。
///
///   parents: 1, 2, 3
///   children: (10 → 1), (11 → 3), (12 → 1)
///   → 1: [10, 12] / 2: [] / 3: [11]
@Test
def testAttach(): Unit \ Assert =
    let attached = Preload.attach({
        parents = List#{1, 2, 3},
        parentKey = parent -> parent,
        children = List#{(10, 1), (11, 3), (12, 1)},
        childKey = child -> snd(child)
    });
    Assert.assertEq(
        expected = List#{(1, List#{(10, 1), (12, 1)}), (2, Nil), (3, List#{(11, 3)})},
        attached)
