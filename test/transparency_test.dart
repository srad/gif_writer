import 'dart:async';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// Transparency, decoded by somebody else.
///
/// `package:image` turns a GIF's transparent index back into an alpha channel —
/// `getPalette()` gives the transparent entry alpha 0 and every other entry 255 —
/// so a decoded pixel's `.a` verifies the semantics against an independent
/// implementation, not against our own reader.
///
/// **Alpha is asserted on single-frame files only.** For an animation the
/// decoder composites each frame onto the one before, so a hole in a later frame
/// shows what was under it rather than alpha 0; the per-frame flag is checked
/// through the raw GCE bytes instead.
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

img.Image decodeFirst(Uint8List bytes) =>
    img.GifDecoder().decode(bytes)!.frames.first;

/// The offset of the first Graphic Control Extension (`21 F9 04 …`), or -1.
///
/// The NETSCAPE loop block is `21 FF`, so it never matches; in these controlled
/// palettes and frames nothing else does either, so the first hit is the GCE.
int gceOffset(Uint8List b) {
  for (var i = 0; i + 8 <= b.length; i++) {
    if (b[i] == 0x21 && b[i + 1] == 0xF9 && b[i + 2] == 0x04) return i;
  }
  return -1;
}

void main() {
  /// RGBA for [colors] (packed `0xRRGGBB`) at [alpha], one entry per pixel.
  Uint8List rgbaOf(List<int> colors, {required List<int> alpha}) {
    final out = Uint8List(colors.length * 4);
    for (var i = 0; i < colors.length; i++) {
      out[i * 4] = (colors[i] >> 16) & 0xFF;
      out[i * 4 + 1] = (colors[i] >> 8) & 0xFF;
      out[i * 4 + 2] = colors[i] & 0xFF;
      out[i * 4 + 3] = alpha[i];
    }
    return out;
  }

  group('addRgbaFrame with transparency', () {
    test(
      'a fully transparent pixel decodes to a hole, an opaque one does not',
      () async {
        // Three opaque colours and one hole, derived table (no colours supplied).
        final rgba = rgbaOf(
          <int>[0xFF0000, 0x00FF00, 0x0000FF, 0x000000],
          alpha: <int>[255, 255, 255, 0],
        );
        final sink = Collector();
        final gif = GifWriter(
          sink,
          width: 2,
          height: 2,
          transparency: GifTransparency(),
        );
        await gif.addRgbaFrame(rgba);
        await gif.close();

        final frame = decodeFirst(sink.bytes);
        expect(frame.getPixel(0, 0).a, 255, reason: 'opaque red');
        expect(frame.getPixel(1, 0).a, 255, reason: 'opaque green');
        expect(frame.getPixel(0, 1).a, 255, reason: 'opaque blue');
        expect(frame.getPixel(1, 1).a, 0, reason: 'the transparent pixel');
      },
    );

    test('the threshold is a strict cutoff', () async {
      // 127 falls below the default 128 and is a hole; 128 is at it and opaque.
      final rgba = rgbaOf(<int>[0xFFFFFF, 0xFFFFFF], alpha: <int>[127, 128]);
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 2,
        height: 1,
        colors: GifColorTable.packed(<int>[0xFFFFFF]),
        transparency: GifTransparency(),
      );
      await gif.addRgbaFrame(rgba);
      await gif.close();

      final frame = decodeFirst(sink.bytes);
      expect(frame.getPixel(0, 0).a, 0, reason: 'alpha 127 < 128');
      expect(frame.getPixel(1, 0).a, 255, reason: 'alpha 128 is not below 128');
    });

    test(
      'background is optional and an opaque pixel keeps its own colour',
      () async {
        final rgba = rgbaOf(<int>[0xFF0000, 0x000000], alpha: <int>[255, 0]);
        final sink = Collector();
        final gif = GifWriter(
          sink,
          width: 2,
          height: 1,
          colors: GifColorTable.packed(<int>[0xFF0000, 0x00FF00]),
          transparency: GifTransparency(),
        );
        // No background: the call is legal, unlike without transparency.
        await gif.addRgbaFrame(rgba);
        await gif.close();

        final frame = decodeFirst(sink.bytes);
        final red = frame.getPixel(0, 0);
        expect(red.a, 255);
        expect(red.r.toInt(), 255);
        expect(red.g.toInt(), 0);
        expect(frame.getPixel(1, 0).a, 0);
      },
    );

    test('an opaque pixel equal to the reserved colour never vanishes', () async {
      // The palette holds a real black at index 0; the reserved slot is another
      // black at the end. An opaque black pixel must map to the real entry, not
      // disappear into the transparent index.
      final rgba = rgbaOf(<int>[0x000000, 0x000000], alpha: <int>[255, 0]);
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 2,
        height: 1,
        colors: GifColorTable.packed(<int>[0x000000, 0xFFFFFF]),
        transparency: GifTransparency(),
      );
      await gif.addRgbaFrame(rgba);
      await gif.close();

      final frame = decodeFirst(sink.bytes);
      final opaqueBlack = frame.getPixel(0, 0);
      expect(opaqueBlack.a, 255, reason: 'opaque black stays opaque');
      expect(opaqueBlack.r.toInt(), 0);
      expect(frame.getPixel(1, 0).a, 0, reason: 'the transparent black');
    });

    test('an all-transparent first frame still writes a valid file', () async {
      final rgba = rgbaOf(<int>[0x123456, 0x654321], alpha: <int>[0, 0]);
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 2,
        height: 1,
        transparency: GifTransparency(),
      );
      await gif.addRgbaFrame(rgba);
      await gif.close();

      final frame = decodeFirst(sink.bytes);
      expect(frame.getPixel(0, 0).a, 0);
      expect(frame.getPixel(1, 0).a, 0);
    });
  });

  group('addIndexedFrame with transparency', () {
    test('a caller can place the transparent index by hand', () async {
      final gif = GifWriter(
        Collector(),
        width: 2,
        height: 1,
        colors: GifColorTable.packed(<int>[0xFF0000, 0x00FF00]),
        transparency: GifTransparency(),
      );
      // Known before any frame, because the table was supplied.
      final hole = gif.transparentIndex;
      expect(hole, isNotNull);

      final sink = Collector();
      final gif2 = GifWriter(
        sink,
        width: 2,
        height: 1,
        colors: GifColorTable.packed(<int>[0xFF0000, 0x00FF00]),
        transparency: GifTransparency(),
      );
      await gif2.addIndexedFrame(Uint8List.fromList(<int>[0, hole!]));
      await gif2.close();

      final frame = decodeFirst(sink.bytes);
      expect(frame.getPixel(0, 0).a, 255, reason: 'index 0 is opaque red');
      expect(frame.getPixel(1, 0).a, 0, reason: 'the transparent index');
    });
  });

  group('the Graphic Control Extension', () {
    test('carries the transparent flag, disposal and index', () async {
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 1,
        height: 1,
        colors: GifColorTable.packed(<int>[0xFF0000]),
        transparency: GifTransparency(disposal: GifDisposal.restoreBackground),
      );
      await gif.addIndexedFrame(Uint8List.fromList(<int>[0]));
      await gif.close();

      final bytes = sink.bytes;
      final o = gceOffset(bytes);
      expect(o, isNonNegative);
      // Packed field: disposal 2 in bits 2-4, transparent flag in bit 0.
      expect(bytes[o + 3], (2 << 2) | 0x01);
      // Transparent index = reserved slot = table length - 1 = 1.
      expect(bytes[o + 6], gif.transparentIndex);
    });

    test('a different disposal is written', () async {
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 1,
        height: 1,
        colors: GifColorTable.packed(<int>[0xFF0000]),
        transparency: GifTransparency(disposal: GifDisposal.doNotDispose),
      );
      await gif.addIndexedFrame(Uint8List.fromList(<int>[0]));
      await gif.close();

      final bytes = sink.bytes;
      expect(bytes[gceOffset(bytes) + 3], (1 << 2) | 0x01);
    });

    test('has the transparent flag clear when transparency is off', () async {
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 1,
        height: 1,
        colors: GifColorTable.packed(<int>[0xFF0000]),
      );
      await gif.addIndexedFrame(Uint8List.fromList(<int>[0]));
      await gif.close();

      final bytes = sink.bytes;
      expect(bytes[gceOffset(bytes) + 3] & 0x01, 0);
    });
  });

  group('reserving the slot', () {
    test('refuses a full 256-colour table', () {
      final full = GifColorTable.packed(<int>[
        for (var i = 0; i < 256; i++) i * 0x010101,
      ]);
      expect(
        () => GifWriter(
          Collector(),
          width: 1,
          height: 1,
          colors: full,
          transparency: GifTransparency(),
        ),
        throwsArgumentError,
      );
    });

    test('transparentIndex is null until a derived table is built', () async {
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: 1,
        height: 1,
        transparency: GifTransparency(),
      );
      expect(gif.transparentIndex, isNull, reason: 'no table yet');
      await gif.addRgbFrame(Uint8List.fromList(<int>[0x10, 0x20, 0x30]));
      expect(gif.transparentIndex, isNotNull, reason: 'derived on first frame');
      await gif.close();
    });

    test('a derived table leaves room and never exceeds 256 entries', () async {
      // A frame with many distinct colours: the quantiser caps the real palette
      // at 255 so the reserved slot fits inside GIF's 256.
      const side = 16;
      final rgba = Uint8List(side * side * 4);
      for (var i = 0; i < side * side; i++) {
        rgba[i * 4] = (i * 7) & 0xFF;
        rgba[i * 4 + 1] = (i * 13) & 0xFF;
        rgba[i * 4 + 2] = (i * 29) & 0xFF;
        rgba[i * 4 + 3] = i.isEven ? 255 : 0;
      }
      final sink = Collector();
      final gif = GifWriter(
        sink,
        width: side,
        height: side,
        transparency: GifTransparency(),
      );
      await gif.addRgbaFrame(rgba);
      await gif.close();

      expect(gif.transparentIndex, isNotNull);
      expect(gif.transparentIndex, lessThanOrEqualTo(255));
      // The file decodes, and its holes are holes.
      final frame = decodeFirst(sink.bytes);
      expect(frame.getPixel(1, 0).a, 0);
    });
  });

  group('GifTransparency', () {
    test('refuses an out-of-range threshold', () {
      expect(() => GifTransparency(alphaThreshold: 0), throwsArgumentError);
      expect(() => GifTransparency(alphaThreshold: 256), throwsArgumentError);
    });

    test('value equality over its fields', () {
      expect(
        GifTransparency(alphaThreshold: 100),
        GifTransparency(alphaThreshold: 100),
      );
      expect(
        GifTransparency(alphaThreshold: 100).hashCode,
        GifTransparency(alphaThreshold: 100).hashCode,
      );
      expect(
        GifTransparency(alphaThreshold: 100),
        isNot(GifTransparency(alphaThreshold: 101)),
      );
      expect(
        GifTransparency(disposal: GifDisposal.doNotDispose),
        isNot(GifTransparency(disposal: GifDisposal.restoreBackground)),
      );
    });
  });
}
