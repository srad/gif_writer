import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'round_trip_test.dart' show RecordingSink;

void main() {
  final dithers = [GifDither.none, GifDither.blueNoise, GifDither.bayer4,
    GifDither.bayer8, GifDither.floydSteinberg, GifDither.atkinson];
  final colors = GifColorTable.packed([0, 0xFFFFFF]);

  for (final dither in dithers) {
    test('$dither ignores hidden RGB across scan directions and edges', () async {
      Future<List<int>> render(int hidden, {bool derive = false}) async {
        const width = 5;
        final rgba = Uint8List(5 * 4 * 4);
        for (var i = 0; i < 20; i++) {
          final hole = i % 3 == 0 || i == 4 || i == 9;
          final value = hole ? hidden : 120;
          rgba.setRange(i * 4, i * 4 + 4, [value, value, value, hole ? 127 : 128]);
        }
        final sink = RecordingSink();
        final gif = GifWriter(sink, width: width, height: 4,
          colors: derive ? null : colors, dither: dither,
          transparency: GifTransparency());
        await gif.addRgbaFrame(rgba);
        await gif.close();
        final decoded = img.GifDecoder().decode(sink.result)!;
        return [for (var i = 0; i < 20; i++) ...[
          decoded.getPixel(i % width, i ~/ width).r.toInt(),
          decoded.getPixel(i % width, i ~/ width).a.toInt(),
        ]];
      }
      for (final derive in [false, true]) {
        final baseline = await render(0, derive: derive);
        expect(await render(120, derive: derive), baseline);
        expect(await render(240, derive: derive), baseline);
        for (var i = 0; i < 20; i++) {
          expect(baseline[i * 2 + 1], i % 3 == 0 || i == 4 || i == 9 ? 0 : 255);
        }
      }
    });

    test('$dither: all-opaque RGBA matches RGB with a derived transparent palette', () async {
      final rgb = Uint8List.fromList([for (var i = 0; i < 32; i++) ...[i * 7, i * 3, i * 5]]);
      final rgba = Uint8List.fromList([for (var i = 0; i < 32; i++) ...[
        rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2], 255,
      ]]);
      final a = RecordingSink();
      final b = RecordingSink();
      final rgbWriter = GifWriter(a, width: 8, height: 4,
        dither: dither, transparency: GifTransparency());
      final rgbaWriter = GifWriter(b, width: 8, height: 4,
        dither: dither, transparency: GifTransparency());
      await rgbWriter.addRgbFrame(rgb);
      await rgbaWriter.addRgbaFrame(rgba);
      await rgbWriter.close();
      await rgbaWriter.close();
      expect(b.result, a.result);
    });
  }

  for (final dither in [GifDither.floydSteinberg, GifDither.atkinson]) {
    test('$dither: hidden grey cannot turn its visible neighbour white', () async {
      final sink = RecordingSink();
      final gif = GifWriter(sink, width: 2, height: 1, colors: colors,
        dither: dither, transparency: GifTransparency());
      await gif.addRgbaFrame(Uint8List.fromList([120, 120, 120, 0, 120, 120, 120, 255]));
      await gif.close();
      final frame = img.GifDecoder().decode(sink.result)!;
      expect(frame.getPixel(0, 0).a, 0);
      expect(frame.getPixel(1, 0).r, 0);
    });
  }
}
