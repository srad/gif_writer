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

  /// The same photographic statistics, in **RGB** — three bytes per pixel, with
  /// colour rather than a single ramp.
  ///
  /// This is what the dither benchmark needs: [photo] is already palettised, so
  /// there would be nothing to map or dither. Here the shading is continuous and
  /// no palette can hold it, which is precisely the case a dither exists for.
  static Uint8List photoRgb({required int side, int seed = 11}) {
    final random = Random(seed);
    final pixels = Uint8List(side * side * 3);
    final discs = <(double x, double y, double r, int rgb)>[
      for (var i = 0; i < 6; i++)
        (
          random.nextDouble() * side,
          random.nextDouble() * side,
          side * (0.12 + random.nextDouble() * 0.22),
          random.nextInt(0x1000000),
        ),
    ];

    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        // A soft two-axis wash for the background, so the frame is full of the
        // slow gradients that band worst when a palette cannot represent them.
        var r = 40.0 + 120.0 * (x / side);
        var g = 60.0 + 100.0 * (y / side);
        var b = 140.0 - 80.0 * ((x + y) / (2 * side));

        for (final (cx, cy, radius, rgb) in discs) {
          final dx = x - cx;
          final dy = y - cy;
          final distance = sqrt(dx * dx + dy * dy);
          if (distance < radius) {
            final shade = 0.55 + 0.45 * (1 - distance / radius);
            r = ((rgb >> 16) & 0xFF) * shade;
            g = ((rgb >> 8) & 0xFF) * shade;
            b = (rgb & 0xFF) * shade;
          }
        }

        // Grain, so runs are not unrealistically long.
        final grain = (random.nextDouble() - 0.5) * 8;
        final p = (y * side + x) * 3;
        pixels[p] = (r + grain).clamp(0, 255).round();
        pixels[p + 1] = (g + grain).clamp(0, 255).round();
        pixels[p + 2] = (b + grain).clamp(0, 255).round();
      }
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
        pixels[y * side + x] = (value.clamp(0, 1) * (colours - 1))
            .round()
            .clamp(0, colours - 1);
      }
    }
    return pixels;
  }
}
