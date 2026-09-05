import 'dart:async';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// Collects everything written, so a finished file can be decoded.
class Collector implements StreamSink<List<int>> {
  final BytesBuilder _builder = BytesBuilder();
  Uint8List get bytes => _builder.toBytes();

  @override
  void add(List<int> data) => _builder.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future<void>.value();
}

final GifColorTable greys = GifColorTable.packed(<int>[
  for (var i = 0; i < 16; i++) (i * 255 ~/ 15) * 0x010101,
]);

/// Decodes with `package:image` — an independent implementation, deliberately.
/// Checking our encoder against our own reader would only prove the two share a
/// misunderstanding.
img.Image decodeFirst(Uint8List bytes) =>
    img.GifDecoder().decode(bytes)!.frames.first;

void main() {
  group('addRgbFrame', () {
    test('round-trips colours that are exactly in the table', () async {
      // Every pixel is a table colour, so there is nothing to dither and the
      // output must be exact — whatever the dither.
      const side = 8;
      final rgb = Uint8List(side * side * 3);
      for (var i = 0; i < side * side; i++) {
        final value = (i % 16) * 255 ~/ 15;
        rgb[i * 3] = value;
        rgb[i * 3 + 1] = value;
        rgb[i * 3 + 2] = value;
      }

      for (final dither in <GifDither>[
        GifDither.none,
        GifDither.blueNoise,
        GifDither.bayer4,
        GifDither.floydSteinberg,
        GifDither.atkinson,
      ]) {
        final sink = Collector();
        final gif = GifWriter(
          sink,
          width: side,
          height: side,
          colors: greys,
          dither: dither,
        );
        await gif.addRgbFrame(rgb);
        await gif.close();

        final decoded = decodeFirst(sink.bytes);
        for (var i = 0; i < side * side; i++) {
          final pixel = decoded.getPixel(i % side, i ~/ side);
          expect(
            pixel.r.toInt(),
            rgb[i * 3],
            reason: '$dither changed an exact colour at $i',
          );
        }
      }
    });

    test('refuses the wrong number of bytes', () {
      final gif = GifWriter(Collector(), width: 4, height: 4, colors: greys);
      expect(
        () => gif.addRgbFrame(Uint8List(4 * 4 * 3 - 1)),
        throwsArgumentError,
      );
    });

    test('dithers a colour the table does not hold', () async {
      // 0x80 lies between two entries. The decoded frame must use both.
      const side = 16;
      final rgb = Uint8List(side * side * 3)
        ..fillRange(0, side * side * 3, 0x80);
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: side,
        height: side,
        colors: greys,
        dither: GifDither.blueNoise,
      );
      await gif.addRgbFrame(rgb);
      await gif.close();

      final decoded = decodeFirst(sink.bytes);
      final used = <int>{};
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          used.add(decoded.getPixel(x, y).r.toInt());
        }
      }
      expect(used.length, greaterThan(1));
      // And it must average out near the colour asked for, rather than drifting.
      final mean = used.reduce((a, b) => a + b) / used.length;
      expect((mean - 0x80).abs(), lessThan(24));
    });
  });

  group('addRgbaFrame', () {
    test('composites alpha over the background', () async {
      // Half-transparent white over black is mid-grey, whatever the palette
      // then does with it.
      final rgba = Uint8List.fromList(<int>[
        for (var i = 0; i < 64; i++) ...<int>[255, 255, 255, 128],
      ]);
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 8,
        height: 8,
        colors: greys,
        dither: GifDither.none,
      );
      await gif.addRgbaFrame(rgba, background: 0x000000);
      await gif.close();

      final decoded = decodeFirst(sink.bytes);
      final value = decoded.getPixel(0, 0).r.toInt();
      // 255 * 128/255 = 128, snapped to the nearest of the 16 grey steps.
      expect((value - 128).abs(), lessThan(12));
    });

    test('an opaque pixel is untouched by the background', () async {
      final rgba = Uint8List.fromList(<int>[
        for (var i = 0; i < 64; i++) ...<int>[255, 255, 255, 255],
      ]);
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 8,
        height: 8,
        colors: greys,
        dither: GifDither.none,
      );
      await gif.addRgbaFrame(rgba, background: 0xFF0000);
      await gif.close();
      expect(decodeFirst(sink.bytes).getPixel(0, 0).r.toInt(), 255);
    });

    test('refuses the wrong number of bytes', () {
      final gif = GifWriter(Collector(), width: 4, height: 4, colors: greys);
      expect(
        () => gif.addRgbaFrame(Uint8List(10), background: 0),
        throwsArgumentError,
      );
    });
  });

  group('deriving the table when none is supplied', () {
    // A colourful frame: enough distinct colours that a derived palette is doing
    // real work, but comfortably under 256 so the round trip stays close.
    Uint8List swatches(int side) {
      final rgb = Uint8List(side * side * 3);
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final p = (y * side + x) * 3;
          rgb[p] = (x * 255 ~/ (side - 1));
          rgb[p + 1] = (y * 255 ~/ (side - 1));
          rgb[p + 2] = 0x40;
        }
      }
      return rgb;
    }

    for (final quantizer in <GifQuantizer>[
      GifQuantizer.octree,
      GifQuantizer.wu,
    ]) {
      test('$quantizer: an RGB frame with no colors: decodes sanely', () async {
        const side = 16;
        final rgb = swatches(side);
        final sink = Collector();
        final gif = GifWriter(
          sink,
          width: side,
          height: side,
          quantizer: quantizer,
          dither: GifDither.none,
        );
        await gif.addRgbFrame(rgb);
        await gif.close();

        final decoded = decodeFirst(sink.bytes);
        expect(decoded.width, side);
        expect(decoded.height, side);
        // Mean error against a palette the encoder chose itself must stay small.
        var total = 0;
        for (var y = 0; y < side; y++) {
          for (var x = 0; x < side; x++) {
            final p = (y * side + x) * 3;
            final pixel = decoded.getPixel(x, y);
            total += (pixel.r.toInt() - rgb[p]).abs();
            total += (pixel.g.toInt() - rgb[p + 1]).abs();
            total += (pixel.b.toInt() - rgb[p + 2]).abs();
          }
        }
        expect(total / (side * side * 3), lessThan(16));
      });

      test('$quantizer: an RGBA frame with no colors: derives too', () async {
        const side = 8;
        final rgba = Uint8List(side * side * 4);
        for (var i = 0; i < side * side; i++) {
          rgba[i * 4] = (i * 3) & 0xFF;
          rgba[i * 4 + 1] = 0x30;
          rgba[i * 4 + 2] = 0x90;
          rgba[i * 4 + 3] = 255;
        }
        final sink = Collector();
        final gif = GifWriter(
          sink,
          width: side,
          height: side,
          quantizer: quantizer,
        );
        await gif.addRgbaFrame(rgba, background: 0x000000);
        await gif.close();
        expect(decodeFirst(sink.bytes).width, side);
      });
    }

    test('an indexed frame with no colors: is refused, not guessed', () {
      // Indices address a palette; they cannot derive one. The writer must say so
      // rather than crash on a null table.
      final gif = GifWriter(Collector(), width: 4, height: 4);
      expect(() => gif.addIndexedFrame(Uint8List(16)), throwsStateError);
    });

    test('closing a table-less writer with no frames still writes a file', () async {
      // The zero-frame guarantee holds even when no palette was ever derived:
      // GIF89a permits a file with no global colour table.
      final sink = Collector();
      final gif = GifWriter(sink, width: 4, height: 4);
      await expectLater(gif.close(), completes);
      // A valid, if empty, GIF: the signature and a trailer at least.
      expect(sink.bytes.sublist(0, 6), <int>[71, 73, 70, 56, 57, 97]);
      expect(sink.bytes.last, 0x3B);
    });
  });

  group('the stream form accepts every frame shape', () {
    test('GifFrame.rgb through pipe matches addRgbFrame', () async {
      const side = 8;
      final rgb = Uint8List(side * side * 3);
      for (var i = 0; i < rgb.length; i++) {
        rgb[i] = (i * 7) & 0xFF;
      }

      final direct = Collector();
      final gifA = GifWriter(direct, width: side, height: side, colors: greys);
      await gifA.addRgbFrame(rgb);
      await gifA.close();

      final piped = Collector();
      await Stream<GifFrame>.fromIterable(<GifFrame>[
        GifFrame.rgb(rgb),
      ]).pipe(GifWriter(piped, width: side, height: side, colors: greys));

      expect(piped.bytes, direct.bytes);
    });

    test('an indexed GifFrame still works, unchanged from 0.1.x', () async {
      final indices = Uint8List.fromList(<int>[
        for (var i = 0; i < 16; i++) i % 16,
      ]);
      final sink = Collector();
      await Stream<GifFrame>.fromIterable(<GifFrame>[
        GifFrame(indices: indices),
      ]).pipe(GifWriter(sink, width: 4, height: 4, colors: greys));

      final decoded = decodeFirst(sink.bytes);
      expect(decoded.getPixel(1, 0).r.toInt(), 255 * 1 ~/ 15);
    });
  });

  test('the indexed path is byte-identical to what 0.1.x produced', () async {
    // **This release must not touch the indexed path.** These bytes were
    // produced before any of the RGB work existed; if they change, something
    // that was supposed to be additive was not.
    final indices = Uint8List.fromList(<int>[
      for (var i = 0; i < 64; i++) i % 16,
    ]);
    final sink = Collector();
    final gif = GifWriter(
      sink,
      width: 8,
      height: 8,
      colors: greys,
      repeat: GifRepeat.forever,
    );
    await gif.addIndexedFrame(indices, delay: const Duration(milliseconds: 50));
    await gif.close();

    expect(sink.bytes, _indexedGolden);
  });
}

/// The exact bytes the encoder produced at commit `9fa1b20`, **before any of the
/// RGB or dithering work existed**.
///
/// Generated by checking that commit out into a scratch directory and running
/// the same calls, not by copying what the current code happens to emit — which
/// would pin the bug rather than the behaviour.
final Uint8List _indexedGolden = Uint8List.fromList(const <int>[
  71,
  73,
  70,
  56,
  57,
  97,
  8,
  0,
  8,
  0,
  243,
  0,
  0,
  0,
  0,
  0,
  17,
  17,
  17,
  34,
  34,
  34,
  51,
  51,
  51,
  68,
  68,
  68,
  85,
  85,
  85,
  102,
  102,
  102,
  119,
  119,
  119,
  136,
  136,
  136,
  153,
  153,
  153,
  170,
  170,
  170,
  187,
  187,
  187,
  204,
  204,
  204,
  221,
  221,
  221,
  238,
  238,
  238,
  255,
  255,
  255,
  33,
  255,
  11,
  78,
  69,
  84,
  83,
  67,
  65,
  80,
  69,
  50,
  46,
  48,
  3,
  1,
  0,
  0,
  0,
  33,
  249,
  4,
  0,
  5,
  0,
  0,
  0,
  44,
  0,
  0,
  0,
  0,
  8,
  0,
  8,
  0,
  0,
  4,
  28,
  16,
  4,
  49,
  72,
  49,
  7,
  37,
  181,
  88,
  115,
  143,
  68,
  89,
  152,
  198,
  121,
  160,
  88,
  93,
  217,
  214,
  125,
  225,
  180,
  150,
  46,
  250,
  68,
  0,
  59,
]);
