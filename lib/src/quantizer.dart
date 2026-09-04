import 'dart:typed_data';

import 'octree.dart';
import 'wu.dart';

/// Which algorithm derives a palette from RGB pixels.
///
/// Reach for one through `GifColorTable.quantize`, or by passing it to
/// `GifWriter`'s `quantizer:` so the writer derives a table from the first frame.
///
/// **The choice is memory against fidelity, and the default guards memory.**
///
/// - [octree] holds no more than the palette itself — a few hundred small nodes,
///   reduced as the image streams in and freed the moment the table is built. It
///   never spikes, which is why it is the default: this package's entire claim is
///   a small, fixed overhead.
/// - [wu] scores slightly better on fidelity (Celebi's 2023 survey ranks its
///   variance-based splitting above octree's population averaging), at the cost
///   of a ~1.4 MB moment histogram while the palette is built. That is transient
///   — one global palette, then freed before a frame streams — so it does not
///   change the held-memory figure, but it is a real allocation the default
///   avoids.
///
/// `tool/quantize.dart` measures the two against each other rather than leaving
/// the trade-off to assertion.
///
/// A plain class with a private constructor and static instances, matching
/// `GifDither` and `GifRepeat`. Not an enum, so a future variant can carry data
/// (a target colour space, say) without reshaping callers.
class GifQuantizer {
  const GifQuantizer._(this._kind);

  /// **The default.** Octree quantisation, bounded to the palette's memory.
  static const GifQuantizer octree = GifQuantizer._(_QuantizerKind.octree);

  /// Wu's greedy orthogonal bipartitioning: higher fidelity, a transient
  /// histogram. See the class docs for the trade-off.
  static const GifQuantizer wu = GifQuantizer._(_QuantizerKind.wu);

  final _QuantizerKind _kind;

  @override
  String toString() => 'GifQuantizer.${_kind.name}';
}

enum _QuantizerKind { octree, wu }

/// The one place that maps a [GifQuantizer] to its engine, so neither
/// `GifColorTable.quantize` nor `GifWriter` repeats the switch.
///
/// Returns packed RGB bytes — three per entry, at most [maxColors] entries —
/// which the caller wraps in a `GifColorTable`.
Uint8List runQuantizer({
  required GifQuantizer quantizer,
  required Uint8List rgb,
  required int maxColors,
}) {
  switch (quantizer._kind) {
    case _QuantizerKind.octree:
      return octreeQuantize(rgb, maxColors: maxColors);
    case _QuantizerKind.wu:
      return wuQuantize(rgb, maxColors: maxColors);
  }
}
