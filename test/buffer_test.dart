import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

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

  test('a frame whose data lands exactly on a block boundary', () async {
    // 255 is the block maximum, so compressed output that is an exact multiple
    // of it ends a block precisely as the data runs out. The encoder must not
    // then open an empty block: a zero-length block is GIF's *terminator*, and
    // one in the middle of a frame truncates the image.
    //
    // The size that lands on the boundary is not predictable from the input, so
    // this sweeps a range and relies on the round trip to catch any of them.
    final colors = grays(4);
    for (var side = 20; side <= 40; side++) {
      final sink = RecordingSink();
      final gif = GifWriter(
        sink,
        width: side,
        height: side,
        colors: colors,
        bufferSize: GifWriter.minBufferSize,
      );
      final pixels = Uint8List.fromList(
        <int>[for (var i = 0; i < side * side; i++) (i * 5 + i ~/ 7) % 4],
      );
      await gif.addIndexedFrame(pixels);
      await gif.close();

      final frame = img.GifDecoder().decode(sink.result)?.frames.single;
      expect(frame, isNotNull, reason: '${side}x$side did not decode');
      for (var i = 0; i < pixels.length; i++) {
        final pixel = frame!.getPixel(i % side, i ~/ side);
        expect(
          (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt(),
          colors[pixels[i]],
          reason: '${side}x$side, pixel $i',
        );
      }
    }
  });
}
