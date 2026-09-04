import 'dart:math';
import 'dart:typed_data';

import 'package:gif_writer/src/color_mapper.dart';
import 'package:gif_writer/src/color_table.dart';
import 'package:gif_writer/src/octree.dart';
import 'package:gif_writer/src/wu.dart';

import 'sample_image.dart';

/// Measures the two quantisers against each other: how faithful the palette is,
/// and how long it takes to derive.
///
/// **This is what backs the default**, rather than the doc-comment claim that
/// octree trades a little fidelity for bounded memory. Run it with
/// `dart run tool/quantize.dart`, or — because the JIT's numbers wander — build
/// it first with `dart compile exe` and run that, the way `ROADMAP.md` asks of
/// the other tools.
///
/// Fidelity is the error after mapping every pixel to its *nearest* derived
/// entry (brute force, so the palette is judged and not the cube's approximation
/// of it). Memory is stated, not timed: octree holds at most the palette — a few
/// hundred small nodes, freed after the call — while Wu holds a fixed 33³ moment
/// histogram of five `Float64List`s, about 1.4 MB, freed just the same. Neither
/// survives into the streaming that follows.
void main() {
  const side = 256;
  const trials = 7;

  final rgb = SampleImage.photoRgb(side: side);

  print('${side}x$side photographic RGB, median of $trials\n');
  print(
    '${'quantiser'.padRight(12)}${'colours'.padLeft(9)}'
    '${'plain err'.padLeft(12)}${'max err'.padLeft(10)}'
    '${'build ms'.padLeft(11)}',
  );

  for (final (name, quantize)
      in <(String, Uint8List Function(Uint8List, {required int maxColors}))>[
        ('octree', octreeQuantize),
        ('wu', wuQuantize),
      ]) {
    final times = <double>[];
    late GifColorTable table;
    for (var t = 0; t < trials; t++) {
      final watch = Stopwatch()..start();
      table = GifColorTable.rgb(quantize(rgb, maxColors: 256));
      watch.stop();
      times.add(watch.elapsedMicroseconds / 1000);
    }
    times.sort();
    final median = times[times.length ~/ 2];
    final (plain, worst) = _fidelity(rgb, table);

    print(
      '${name.padRight(12)}${table.length.toString().padLeft(9)}'
      '${plain.toStringAsFixed(2).padLeft(12)}${worst.toString().padLeft(10)}'
      '${median.toStringAsFixed(2).padLeft(11)}',
    );
  }
}

/// Root-mean-square error over all channels, and the single worst channel error,
/// when each pixel takes its nearest palette entry.
(double plain, int worst) _fidelity(Uint8List rgb, GifColorTable table) {
  final mapper = ColorMapper(table);
  var sum = 0.0;
  var worst = 0;
  for (var p = 0; p < rgb.length; p += 3) {
    final r = rgb[p], g = rgb[p + 1], b = rgb[p + 2];
    final i = mapper.exactNearest(r: r, g: g, b: b);
    final dr = r - mapper.redAt(i);
    final dg = g - mapper.greenAt(i);
    final db = b - mapper.blueAt(i);
    sum += dr * dr + dg * dg + db * db;
    for (final d in <int>[dr.abs(), dg.abs(), db.abs()]) {
      if (d > worst) worst = d;
    }
  }
  return (sqrt(sum / rgb.length), worst);
}
