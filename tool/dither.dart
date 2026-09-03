import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:gif_writer/src/color_mapper.dart';
import 'package:gif_writer/src/dither.dart';

import 'sample_image.dart';

/// Measures every dither: how big the file is, how fast it encodes, and how
/// close it looks.
///
/// **This is what picks the default**, rather than an assertion in a doc comment.
/// Run it with `dart run tool/dither.dart`.
///
/// The quality column is the one that needs care. See [blurredError].
final class CountingSink implements StreamSink<List<int>> {
  int bytes = 0;
  @override
  void add(List<int> data) => bytes += data.length;
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future<void>.value();
}

/// Root-mean-square error after a **5x5 box blur of both images**.
///
/// **Plain per-pixel error is the wrong metric for a dither, and using it would
/// pick the wrong default.** A dithered pixel is deliberately the *wrong*
/// colour — the right one on average across its neighbours — so per-pixel error
/// ranks `GifDither.none`, which never dithers, as the most accurate of all
/// while looking the worst. Blurring first measures what the eye does at a
/// normal viewing distance, which is the thing dithering is for.
///
/// Plain error is reported beside it, precisely so the divergence is visible.
double blurredError({
  required Uint8List original,
  required Uint8List reconstructed,
  required int side,
}) {
  final a = _blur(original, side);
  final b = _blur(reconstructed, side);
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    sum += d * d;
  }
  return sqrt(sum / a.length);
}

/// How **structured** the dither's error is: the peak of its spectrum against
/// the mean, over a 64x64 crop.
///
/// **The blurred error above cannot see this, and that is not a flaw in it —
/// blurring destroys high-frequency structure by design, which is exactly where
/// an ordered dither's artefact lives.** So it rates a Bayer grid and blue noise
/// as identical, when the whole reason blue noise exists is that a regular grid
/// is far more objectionable to look at than unstructured texture of the same
/// amplitude.
///
/// A periodic artefact concentrates its energy in a few frequency bins, so the
/// peak towers over the mean. Unstructured noise spreads evenly and the ratio
/// stays near one. Higher is worse.
double spectralPeak({
  required Uint8List original,
  required Uint8List reconstructed,
  required int side,
}) {
  const crop = 64;
  final error = Float64List(crop * crop);
  for (var y = 0; y < crop; y++) {
    for (var x = 0; x < crop; x++) {
      final p = (y * side + x) * 3;
      // Luma of the error, which is what the eye picks the pattern out of.
      error[y * crop + x] = 0.299 * (original[p] - reconstructed[p]) +
          0.587 * (original[p + 1] - reconstructed[p + 1]) +
          0.114 * (original[p + 2] - reconstructed[p + 2]);
    }
  }
  final mean = error.reduce((a, b) => a + b) / error.length;
  for (var i = 0; i < error.length; i++) {
    error[i] -= mean;
  }

  var peak = 0.0;
  var total = 0.0;
  var bins = 0;
  for (var v = 0; v < crop; v++) {
    for (var u = 0; u < crop; u++) {
      if (u == 0 && v == 0) continue;
      var re = 0.0;
      var im = 0.0;
      for (var y = 0; y < crop; y++) {
        for (var x = 0; x < crop; x++) {
          final angle = -2 * pi * (u * x + v * y) / crop;
          re += error[y * crop + x] * cos(angle);
          im += error[y * crop + x] * sin(angle);
        }
      }
      final power = re * re + im * im;
      if (power > peak) peak = power;
      total += power;
      bins++;
    }
  }
  final average = total / bins;
  return average == 0 ? 0 : peak / average;
}

double plainError({
  required Uint8List original,
  required Uint8List reconstructed,
}) {
  var sum = 0.0;
  for (var i = 0; i < original.length; i++) {
    final d = original[i] - reconstructed[i];
    sum += d * d;
  }
  return sqrt(sum / original.length);
}

Float32List _blur(Uint8List rgb, int side) {
  const radius = 2;
  final out = Float32List(rgb.length);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      for (var c = 0; c < 3; c++) {
        var sum = 0.0;
        var n = 0;
        for (var dy = -radius; dy <= radius; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= side) continue;
          for (var dx = -radius; dx <= radius; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= side) continue;
            sum += rgb[(yy * side + xx) * 3 + c];
            n++;
          }
        }
        out[(y * side + x) * 3 + c] = sum / n;
      }
    }
  }
  return out;
}

/// A fixed uniform palette: [levels] steps per channel.
///
/// Uniform rather than derived from the image, because this package has no
/// quantiser yet — and because a fixed palette is the harder, more honest test:
/// it cannot flatter a dither by already containing the image's colours.
GifColorTable uniformPalette(int levels) => GifColorTable.packed(<int>[
  for (var r = 0; r < levels; r++)
    for (var g = 0; g < levels; g++)
      for (var b = 0; b < levels; b++)
        ((r * 255 ~/ (levels - 1)) << 16) |
            ((g * 255 ~/ (levels - 1)) << 8) |
            (b * 255 ~/ (levels - 1)),
]);

Future<void> main() async {
  const side = 256;
  const frames = 30;
  const trials = 5;

  final rgb = SampleImage.photoRgb(side: side);

  const dithers = <(String, GifDither)>[
    ('none', GifDither.none),
    ('bayer4', GifDither.bayer4),
    ('bayer8', GifDither.bayer8),
    ('blueNoise', GifDither.blueNoise),
    ('floydSteinberg', GifDither.floydSteinberg),
    ('atkinson', GifDither.atkinson),
  ];

  for (final (levels, label) in <(int, String)>[
    (3, '27 colours (3 per channel)'),
    (6, '216 colours (6 per channel)'),
  ]) {
    final table = uniformPalette(levels);
    print('\n$label - $frames frames of ${side}x$side, median of $trials\n');
    print('${'dither'.padRight(16)}${'blurred err'.padLeft(12)}'
        '${'structure'.padLeft(11)}${'plain err'.padLeft(11)}'
        '${'output'.padLeft(11)}${'rate'.padLeft(14)}');

    for (final (name, dither) in dithers) {
      // What the decoder would show: indices mapped back through the palette.
      final mapper = ColorMapper(table);
      final runner = DitherRunner(
        dither: dither,
        mapper: mapper,
        width: side,
      );
      final indices = Uint8List(side * side);
      runner.mapRgb(rgb: rgb, out: indices);
      final shown = Uint8List(rgb.length);
      for (var i = 0; i < indices.length; i++) {
        shown[i * 3] = mapper.redAt(indices[i]);
        shown[i * 3 + 1] = mapper.greenAt(indices[i]);
        shown[i * 3 + 2] = mapper.blueAt(indices[i]);
      }

      final blurred = blurredError(
        original: rgb,
        reconstructed: shown,
        side: side,
      );
      final plain = plainError(original: rgb, reconstructed: shown);
      final structure = spectralPeak(
        original: rgb,
        reconstructed: shown,
        side: side,
      );

      // Warm, then time.
      for (var w = 0; w < 2; w++) {
        final gif = GifWriter(
          CountingSink(),
          width: side,
          height: side,
          colors: table,
          dither: dither,
        );
        await gif.addRgbFrame(rgb);
        await gif.close();
      }

      final times = <double>[];
      var bytes = 0;
      for (var t = 0; t < trials; t++) {
        final sink = CountingSink();
        final gif = GifWriter(
          sink,
          width: side,
          height: side,
          colors: table,
          dither: dither,
        );
        final watch = Stopwatch()..start();
        for (var f = 0; f < frames; f++) {
          await gif.addRgbFrame(rgb);
        }
        await gif.close();
        watch.stop();
        times.add(watch.elapsedMicroseconds / 1000);
        bytes = sink.bytes;
      }
      times.sort();
      final rate = side * side * frames / (times[trials ~/ 2] * 1000);

      print('${name.padRight(16)}'
          '${blurred.toStringAsFixed(2).padLeft(12)}'
          '${structure.toStringAsFixed(0).padLeft(11)}'
          '${plain.toStringAsFixed(2).padLeft(11)}'
          '${'${(bytes / 1024 / 1024).toStringAsFixed(2)} MB'.padLeft(11)}'
          '${'${rate.toStringAsFixed(1)} Mpx/s'.padLeft(14)}');
    }
  }

  print('\nLower error is better. **Blurred error is the one that matters** - '
      'plain per-pixel\nerror rewards not dithering at all, which is why '
      'both are shown.');

  // --- the Bayer-versus-blue-noise question, isolated ----------------------
  //
  // On photographic content the `structure` column above is dominated by the
  // *image's* own edges and gradients, not by the dither's pattern, so it cannot
  // separate a Bayer grid from blue noise. On a flat field there is nothing to
  // see except what the dither itself put there — which is exactly the case
  // where a regular grid is most objectionable.
  print('\n\nflat mid-tone field - the only structure here is the dither\'s own\n');
  print('${'dither'.padRight(16)}${'structure'.padLeft(11)}'
      '${'output'.padLeft(11)}');

  final table = uniformPalette(3);
  final flat = Uint8List(side * side * 3);
  for (var i = 0; i < flat.length; i++) {
    // Halfway between two levels of a 3-per-channel palette: maximum work for
    // the dither, and nothing else in the frame.
    flat[i] = 64;
  }

  for (final (name, dither) in dithers) {
    final mapper = ColorMapper(table);
    final runner = DitherRunner(dither: dither, mapper: mapper, width: side);
    final indices = Uint8List(side * side);
    runner.mapRgb(rgb: flat, out: indices);
    final shown = Uint8List(flat.length);
    for (var i = 0; i < indices.length; i++) {
      shown[i * 3] = mapper.redAt(indices[i]);
      shown[i * 3 + 1] = mapper.greenAt(indices[i]);
      shown[i * 3 + 2] = mapper.blueAt(indices[i]);
    }

    final sink = CountingSink();
    final gif = GifWriter(
      sink,
      width: side,
      height: side,
      colors: table,
      dither: dither,
    );
    await gif.addRgbFrame(flat);
    await gif.close();

    print('${name.padRight(16)}'
        '${spectralPeak(original: flat, reconstructed: shown, side: side).toStringAsFixed(0).padLeft(11)}'
        '${'${(sink.bytes / 1024).toStringAsFixed(1)} kB'.padLeft(11)}');
  }
}
