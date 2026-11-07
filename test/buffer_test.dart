import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'lzw_termination_test.dart' show decodePayload, imageData;
import 'round_trip_test.dart' show RecordingSink;

/// The staging buffer, and the corruption it can cause when it is too small.
///
/// A GIF sub-block is a length byte followed by up to 255 bytes of data. The
/// encoder reserves that length byte, writes straight into the buffer, and
/// patches the length once the block is done — which removes a copy of the
/// entire compressed output, and introduces a way to be silently wrong: if the
/// buffer could **flush between the reservation and the patch**, the patch lands
/// on a stale position and overwrites somebody else's byte. Nothing throws. The
/// file is simply broken, somewhere in the middle.
///
/// These tests exist because that failure has no other symptom.
void main() {
  GifColorTable grays(int count) => GifColorTable.packed(<int>[
    for (var i = 0; i < count; i++) (i * 255 ~/ (count - 1)) * 0x010101,
  ]);

  /// Noise, so it does not compress into a handful of blocks — the point is to
  /// produce many of them and force many flushes.
  Uint8List noise({required int side, int phase = 0}) => Uint8List.fromList(
    <int>[for (var i = 0; i < side * side; i++) (i * 7 + i ~/ 3 + phase) % 16],
  );

  test('a buffer too small to hold one block is refused', () {
    // Refused at construction, not tolerated: 255 bytes is enough to open a
    // block and not enough to finish it.
    for (final tooSmall in <int>[0, 1, 255, 256, GifWriter.minBufferSize - 1]) {
      expect(
        () => GifWriter(
          RecordingSink(),
          width: 8,
          height: 8,
          colors: grays(4),
          bufferSize: tooSmall,
        ),
        throwsArgumentError,
        reason: 'a $tooSmall-byte buffer was accepted',
      );
    }
  });

  test('the smallest allowed buffer still writes a correct file', () async {
    // The case the guard exists for. At the minimum the buffer flushes
    // constantly — dozens of times inside a single frame — so if a flush could
    // ever land inside a block, this is where it would.
    const side = 96;
    final colors = grays(16);
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: side,
      height: side,
      colors: colors,
      bufferSize: GifWriter.minBufferSize,
    );
    final pixels = noise(side: side);
    await gif.addIndexedFrame(pixels);
    await gif.close();

    final decoded = img.GifDecoder().decode(sink.result);
    expect(decoded, isNotNull, reason: 'the file did not decode at all');
    final frame = decoded!.frames.single;
    for (var i = 0; i < pixels.length; i++) {
      final pixel = frame.getPixel(i % side, i ~/ side);
      expect(
        (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt(),
        colors[pixels[i]],
        reason: 'pixel $i differs — a block was split across a flush',
      );
    }
  });

  test('every buffer size produces byte-identical output', () async {
    // The buffer is a staging detail and must not reach the file. If it does,
    // one of these differs — and the sizes are chosen to straddle a block: 1024
    // holds four, 64 kB holds hundreds.
    const side = 64;
    Future<Uint8List> encodeWith(int bufferSize) async {
      final sink = RecordingSink();
      final gif = GifWriter(
        sink,
        width: side,
        height: side,
        colors: grays(16),
        bufferSize: bufferSize,
      );
      for (var f = 0; f < 3; f++) {
        await gif.addIndexedFrame(noise(side: side, phase: f));
      }
      await gif.close();
      return sink.result;
    }

    final reference = await encodeWith(64 * 1024);
    for (final size in <int>[1024, 1031, 4096, 16 * 1024]) {
      expect(
        await encodeWith(size),
        reference,
        reason: 'a $size-byte buffer changed the file',
      );
    }
  });

  for (final capacity in [GifWriter.minBufferSize, 64 * 1024]) {
    test('a full final sub-block with a $capacity-byte staging buffer', () async {
      // This seeded fixture compresses to exactly 255 bytes, including EOI.
      // Assert the boundary itself: sweeping image sizes without checking the
      // compressed length previously left this path untested.
      const width = 810;
      var state = 12345;
      final pixels = Uint8List(width);
      for (var i = 0; i < width; i++) {
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
        pixels[i] = (state >> 16) & 3;
      }
      final colors = grays(4);
      final sink = RecordingSink();
      final gif = GifWriter(
        sink,
        width: width,
        height: 1,
        colors: colors,
        repeat: GifRepeat.once,
        bufferSize: capacity,
      );
      await gif.addIndexedFrame(pixels);
      await gif.close();

      final data = imageData(sink.result);
      expect(data.blockLengths, [255]);
      expect(data.payload, hasLength(255));
      expect(decodePayload(payload: data.payload, minimum: data.minimum,
        expected: width).pixels, pixels);
      final frame = img.GifDecoder().decode(sink.result)?.frames.single;
      expect(frame, isNotNull);
      for (var i = 0; i < pixels.length; i++) {
        final pixel = frame!.getPixel(i, 0);
        expect(
          (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt(),
          colors[pixels[i]],
          reason: 'pixel $i',
        );
      }
    });
  }
}
