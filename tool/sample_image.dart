import 'dart:math';
import 'dart:typed_data';

/// Test images for the benchmarks, generated rather than bundled.
///
/// **Why not a real photograph.** The image-processing habit is to reach for
/// "Lenna", which IEEE retired in 2024 and most venues have dropped over its
/// provenance; and bundling any photo adds weight to the package and a licence
/// to reason about. What actually drives an LZW encoder is the *statistics* of
/// the content — how long its runs are, how often the dictionary matches — and
/// those can be generated exactly and reproducibly.
///
/// Three workloads, because a single number hides the range. Real photographic
/// content sits between [noise] and [smooth]; [photo] is built to land there.
abstract final class SampleImage {
  /// Uniform random indices: **the worst case**. Nothing repeats, so the
  /// dictionary fills with entries that are never matched again and the output
  /// is larger than the input.
  static Uint8List noise({
    required int side,
    required int colours,
    int seed = 7,
  }) {
    final random = Random(seed);
    final pixels = Uint8List(side * side);
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] = random.nextInt(colours);
    }
    return pixels;
  }

  /// A vertical gradient: **the best case**. Long runs of one index, which LZW
  /// collapses to almost nothing.
  static Uint8List smooth({required int side, required int colours}) {
    final pixels = Uint8List(side * side);
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] = ((i ~/ side) * colours ~/ side).clamp(0, colours - 1);
    }
    return pixels;
  }

  /// Photographic statistics: smooth shading, hard edges, and fine grain.
  ///
  /// The three things that decide how a photograph compresses. Shading gives
  /// long runs; the edges break them, which is what fills the dictionary; the
  /// grain stops runs being unrealistically long, which is the flaw in
  /// benchmarking on a gradient alone.
  static Uint8List photo({
    required int side,
    required int colours,
    int seed = 11,
  }) {
    final random = Random(seed);
    final pixels = Uint8List(side * side);
    // A handful of overlapping discs, the way a photograph has a few subjects
    // against a background rather than uniform detail everywhere.
    final discs = <(double x, double y, double r, double v)>[
      for (var i = 0; i < 5; i++)
        (
          random.nextDouble() * side,
          random.nextDouble() * side,
          side * (0.12 + random.nextDouble() * 0.22),
          random.nextDouble(),
        ),
    ];

    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        // Background: a soft diagonal wash.
        var value = 0.25 + 0.35 * ((x + y) / (2 * side));
        for (final (cx, cy, r, v) in discs) {
          final dx = x - cx;
          final dy = y - cy;
          final distance = sqrt(dx * dx + dy * dy);
          if (distance < r) {
            // Shaded inside, and a hard edge at the rim — the edge is the part
            // that matters, because it is where the runs stop.
            value = v * (0.55 + 0.45 * (1 - distance / r));
          }
        }
        // Grain, small enough to read as texture rather than as noise.
        value += (random.nextDouble() - 0.5) * 0.06;
        pixels[y * side + x] =
            (value.clamp(0, 1) * (colours - 1)).round().clamp(0, colours - 1);
      }
    }
    return pixels;
  }
}
