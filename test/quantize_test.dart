import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

/// Deriving a palette from pixels — octree and Wu, held to the same contract.
///
/// The properties that matter are the same for both algorithms: never exceed the
/// cap, keep colours the image already fits, and give the same answer twice. The
/// two differ only in *how good* the palette is, which is a measurement
/// (`tool/quantize.dart`), not an assertion — a test that ranked them would be a
/// test of one particular image.
void main() {
  // Colours far enough apart to sit in different 5-bit bins, so Wu's histogram
  // resolves them as separate boxes rather than merging two into one.
  const black = 0x000000;
  const grey = 0x808080;
  const white = 0xFFFFFF;

  for (final quantizer in <GifQuantizer>[
    GifQuantizer.octree,
    GifQuantizer.wu,
  ]) {
    group('$quantizer', () {
      test('never returns more than the cap', () {
        final rgb = _gradient(side: 48); // far more than 256 distinct colours
        final table = GifColorTable.quantize(
          rgb,
          maxColors: 256,
          quantizer: quantizer,
        );
        expect(table.length, inInclusiveRange(1, 256));
      });

      test('keeps colours the image already fits within the cap', () {
        // Three well-separated colours, cap of sixteen: nothing needs merging, so
        // the palette should be exactly those three.
        final rgb = _fromColours(<int>[black, grey, white], each: 20);
        final table = GifColorTable.quantize(
          rgb,
          maxColors: 16,
          quantizer: quantizer,
        );
        expect(_coloursOf(table), <int>{black, grey, white});
      });

      test('a single colour becomes a one-entry table of that colour', () {
        final rgb = _fromColours(<int>[0x336699], each: 50);
        final table = GifColorTable.quantize(rgb, quantizer: quantizer);
        expect(table.length, 1);
        expect(table[0], 0x336699);
      });

      test('two clusters under a cap of two land on the two colours', () {
        final rgb = _fromColours(<int>[black, white], each: 100);
        final table = GifColorTable.quantize(
          rgb,
          maxColors: 2,
          quantizer: quantizer,
        );
        expect(_coloursOf(table), <int>{black, white});
      });

      test('reconstructs a gradient within a bounded error', () {
        // Not a quality contest between the two — just that mapping every pixel
        // to its nearest derived entry stays well under a visible drift.
        final rgb = _gradient(side: 48);
        final table = GifColorTable.quantize(rgb, quantizer: quantizer);
        expect(_meanNearestError(rgb, table), lessThan(12));
      });

      test('is deterministic — identical pixels, identical table', () {
        final rgb = _gradient(side: 40);
        final a = GifColorTable.quantize(rgb, quantizer: quantizer);
        final b = GifColorTable.quantize(rgb, quantizer: quantizer);
        expect(a.toBytes(), b.toBytes());
      });
    });
  }
}

/// A smooth RGB ramp with far more than 256 distinct colours — the case a
/// palette cannot hold and a quantiser exists for.
Uint8List _gradient({required int side}) {
  final rgb = Uint8List(side * side * 3);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final p = (y * side + x) * 3;
      rgb[p] = (x * 255 ~/ (side - 1));
      rgb[p + 1] = (y * 255 ~/ (side - 1));
      rgb[p + 2] = ((x + y) * 255 ~/ (2 * (side - 1)));
    }
  }
  return rgb;
}

/// [each] pixels of every packed colour in [colours], in order.
Uint8List _fromColours(List<int> colours, {required int each}) {
  final rgb = Uint8List(colours.length * each * 3);
  var p = 0;
  for (final c in colours) {
    for (var i = 0; i < each; i++) {
      rgb[p++] = (c >> 16) & 0xFF;
      rgb[p++] = (c >> 8) & 0xFF;
      rgb[p++] = c & 0xFF;
    }
  }
  return rgb;
}

Set<int> _coloursOf(GifColorTable table) => <int>{
  for (var i = 0; i < table.length; i++) table[i],
};

/// Mean per-channel absolute error when each pixel takes its nearest palette
/// entry — a plain fidelity number, brute-forced for the test's sake.
double _meanNearestError(Uint8List rgb, GifColorTable table) {
  var total = 0;
  final pixels = rgb.length ~/ 3;
  for (var p = 0; p < rgb.length; p += 3) {
    final r = rgb[p], g = rgb[p + 1], b = rgb[p + 2];
    var bestD = 1 << 30;
    var bestR = 0, bestG = 0, bestB = 0;
    for (var i = 0; i < table.length; i++) {
      final e = table[i];
      final er = (e >> 16) & 0xFF, eg = (e >> 8) & 0xFF, eb = e & 0xFF;
      final dr = r - er, dg = g - eg, db = b - eb;
      final d = dr * dr + dg * dg + db * db;
      if (d < bestD) {
        bestD = d;
        bestR = er;
        bestG = eg;
        bestB = eb;
      }
    }
    total += (r - bestR).abs() + (g - bestG).abs() + (b - bestB).abs();
  }
  return total / (pixels * 3);
}
