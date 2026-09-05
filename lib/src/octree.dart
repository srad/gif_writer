import 'dart:typed_data';

/// Octree colour quantisation (Gervautz–Purgathofer, 1988).
///
/// Derives a palette of at most [maxColors] entries from [rgb] — three bytes per
/// pixel — and returns it as packed RGB bytes, ready for `GifColorTable.rgb`.
///
/// **Why octree here.** Its memory is bounded by the *palette*, not the image:
/// the tree never holds more than about [maxColors] live leaves, because it is
/// reduced *as it is built* rather than grown to completion and pruned at the
/// end. That is the property this package is built around — a fixed, small
/// overhead — and it is why octree is the default. `wu.dart` offers variance-based
/// splitting with larger transient tables; `tool/quantize.dart` compares quality
/// on generated input.
///
/// **Web-safe.** The per-channel sums reach at most `255 * pixelCount`, which for
/// a 16-megapixel frame is about 4.3e9 — well inside the 53-bit integers a `double`
/// holds, so this is correct where `int` is a `double`.
Uint8List octreeQuantize(Uint8List rgb, {required int maxColors}) {
  assert(maxColors >= 1, 'a palette needs at least one colour');
  assert(rgb.length % 3 == 0, 'rgb must be three bytes per pixel');

  final tree = _Octree(maxColors: maxColors);
  for (var i = 0; i < rgb.length; i += 3) {
    tree.add(r: rgb[i], g: rgb[i + 1], b: rgb[i + 2]);
  }
  return tree.palette();
}

/// Eight bits per channel, so eight levels deep: one branch decision per bit,
/// most-significant first.
const int _maxDepth = 8;

class _Octree {
  _Octree({required this.maxColors})
    : _root = _Node(level: 0, isLeaf: false),
      // One bucket of reducible nodes per interior level (0..7). A node lands in
      // its level's bucket the moment it gains a first child, and leaves it when
      // it is folded back into a leaf.
      _reducible = List<List<_Node>>.generate(_maxDepth, (_) => <_Node>[]);

  final int maxColors;
  final _Node _root;
  final List<List<_Node>> _reducible;
  int _leaves = 0;

  void add({required int r, required int g, required int b}) {
    _addTo(_root, r: r, g: g, b: b, level: 0);
    // Reduce *between* insertions, not once at the end: this is what keeps the
    // live node count near the palette size instead of near the count of
    // distinct colours, which is the whole memory argument for octree.
    while (_leaves > maxColors) {
      _reduce();
    }
  }

  void _addTo(
    _Node node, {
    required int r,
    required int g,
    required int b,
    required int level,
  }) {
    // Every node on the path carries its subtree's totals, so a folded node is
    // already its own average and reduction needs no second walk.
    node.count++;
    node.sumR += r;
    node.sumG += g;
    node.sumB += b;
    if (node.isLeaf) return;

    // The branch is the three colour bits at this depth, MSB first: bit 7 at
    // level 0 down to bit 0 at level 7.
    final shift = 7 - level;
    final index =
        (((r >> shift) & 1) << 2) |
        (((g >> shift) & 1) << 1) |
        ((b >> shift) & 1);

    var child = node.children![index];
    if (child == null) {
      final atLeafLevel = level + 1 == _maxDepth;
      child = _Node(level: level + 1, isLeaf: atLeafLevel);
      node.children![index] = child;
      if (node.childCount == 0) _reducible[level].add(node);
      node.childCount++;
      if (atLeafLevel) _leaves++;
    }
    _addTo(child, r: r, g: g, b: b, level: level + 1);
  }

  /// Folds one interior node back into a leaf, at the deepest level that has one.
  ///
  /// The deepest reducible node's children are guaranteed to be leaves — if one
  /// had children of its own it would sit at a deeper level, contradicting
  /// "deepest". So the fold turns `childCount` leaves into one, and the node's
  /// already-accumulated sums are the merged colour.
  void _reduce() {
    var level = _maxDepth - 1;
    while (level > 0 && _reducible[level].isEmpty) {
      level--;
    }
    final bucket = _reducible[level];

    // Least-populated first: the fewest pixels means the smallest visible change
    // when its shades collapse to one. Ties go to the earliest in the bucket, so
    // the choice is deterministic and the palette is reproducible.
    var pick = 0;
    for (var i = 1; i < bucket.length; i++) {
      if (bucket[i].count < bucket[pick].count) pick = i;
    }
    final node = bucket.removeAt(pick);

    _leaves -= node.childCount - 1;
    node.isLeaf = true;
    node.children = null;
    node.childCount = 0;
  }

  Uint8List palette() {
    // Copying builder: the 3-byte scratch below is reused per entry, so the
    // builder must take a copy of each rather than a reference to it.
    final out = BytesBuilder();
    final rgb = Uint8List(3);
    void walk(_Node node) {
      if (node.isLeaf) {
        // Rounded, not truncated, matching the compositor: `+ half` keeps a long
        // run of shades from settling a level darker than their true mean.
        final half = node.count >> 1;
        rgb[0] = (node.sumR + half) ~/ node.count;
        rgb[1] = (node.sumG + half) ~/ node.count;
        rgb[2] = (node.sumB + half) ~/ node.count;
        out.add(rgb);
        return;
      }
      // Fixed child order, so the palette's index order is deterministic.
      for (final child in node.children!) {
        if (child != null) walk(child);
      }
    }

    walk(_root);
    return out.toBytes();
  }
}

class _Node {
  _Node({required this.level, required this.isLeaf})
    : children = isLeaf ? null : List<_Node?>.filled(8, null);

  final int level;
  bool isLeaf;

  int count = 0;
  int sumR = 0;
  int sumG = 0;
  int sumB = 0;

  List<_Node?>? children;
  int childCount = 0;
}
