import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

import 'round_trip_test.dart' show RecordingSink;

/// Looping, which GIF expresses in a way nothing else about the format prepares
/// you for.
///
/// There is no "loop" field. Repeating is a **Netscape application extension** —
/// a vendor block from 1995 that every decoder now honours — and it must sit
/// after the global colour table and before the first frame. Its payload is the
/// number of *additional* plays, so zero means forever and one means twice.
///
/// The off-by-one there is the whole reason these tests exist: a file that plays
/// twice when it was asked to play once is not something a round-trip test
/// notices, because the pixels are perfect.
void main() {
  /// The bytes of a one-frame file written with [repeat].
  Future<Uint8List> fileWith(GifRepeat repeat) async {
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: 2,
      height: 2,
      colors: GifColorTable.packed(<int>[0x000000, 0xFFFFFF]),
      repeat: repeat,
    );
    await gif.addIndexedFrame(Uint8List.fromList(<int>[0, 1, 1, 0]));
    await gif.close();
    return sink.result;
  }

  /// Where the Netscape block starts, or -1.
  ///
  /// Found by its signature rather than by offset, because the header's length
  /// depends on the colour table and hard-coding a position would make this test
  /// fail for the wrong reason later.
  int netscapeAt(Uint8List bytes) {
    const signature = <int>[0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45];
    outer:
    for (var i = 0; i + signature.length < bytes.length; i++) {
      for (var j = 0; j < signature.length; j++) {
        if (bytes[i + j] != signature[j]) continue outer;
      }
      return i - 3; // back up over 0x21 0xFF 0x0B
    }
    return -1;
  }

  test('forever writes a loop count of zero', () async {
    final bytes = await fileWith(GifRepeat.forever);
    final at = netscapeAt(bytes);
    expect(at, isNonNegative, reason: 'no Netscape block at all');
    // 0x21 0xFF 0x0B, "NETSCAPE2.0", 0x03 0x01, then two little-endian bytes.
    expect(bytes[at], 0x21);
    expect(bytes[at + 1], 0xFF);
    expect(bytes[at + 2], 0x0B);
    expect(bytes[at + 14], 0x03);
    expect(bytes[at + 15], 0x01);
    expect(bytes[at + 16] | (bytes[at + 17] << 8), 0);
    expect(bytes[at + 18], 0x00, reason: 'the block must be terminated');
  });

  test('once writes no block at all', () async {
    // Not a count of one. "Play once more" and "do not loop" are different
    // things, and a decoder told to loop once plays the animation twice.
    final bytes = await fileWith(GifRepeat.once);
    expect(
      netscapeAt(bytes),
      -1,
      reason: 'a looping block was written for a file that should not loop',
    );
  });

  test('times(n) writes n - 1, because the field counts repeats', () async {
    for (final total in <int>[2, 3, 10, 1000]) {
      final bytes = await fileWith(GifRepeat.times(total));
      final at = netscapeAt(bytes);
      expect(at, isNonNegative, reason: 'times($total) wrote no block');
      expect(
        bytes[at + 16] | (bytes[at + 17] << 8),
        total - 1,
        reason: 'times($total) should ask for ${total - 1} extra plays',
      );
    }
  });

  test('the largest expressible count still writes a block', () async {
    // 65536 total plays is 65535 extra, which is exactly what two bytes hold.
    final bytes = await fileWith(GifRepeat.times(65536));
    final at = netscapeAt(bytes);
    expect(at, isNonNegative);
    expect(bytes[at + 16] | (bytes[at + 17] << 8), 0xFFFF);
  });

  test('a count too large for two bytes is refused, not truncated', () {
    // The failure this prevents is silent: `times(70000)` stores 69999 and the
    // low sixteen bits are 4463, so the file plays 4463 times and every pixel
    // in it is perfect. Nothing downstream can notice.
    for (final total in <int>[65537, 70000, 1 << 20]) {
      expect(
        () => GifRepeat.times(total),
        throwsArgumentError,
        reason: 'times($total) does not fit and must not be truncated',
      );
    }
  });

  test('times(1) and below mean once, so no block', () async {
    for (final total in <int>[1, 0, -5]) {
      expect(
        netscapeAt(await fileWith(GifRepeat.times(total))),
        -1,
        reason: 'times($total) wrote a looping block',
      );
    }
  });

  test('the block sits before the first frame', () async {
    // Order is not cosmetic: an application extension after the first image
    // descriptor applies to nothing, and decoders ignore it.
    final bytes = await fileWith(GifRepeat.forever);
    final loop = netscapeAt(bytes);
    final firstImage = bytes.indexOf(0x2C);
    expect(firstImage, isNonNegative, reason: 'no image descriptor');
    expect(
      loop,
      lessThan(firstImage),
      reason: 'the looping block came after the first frame',
    );
  });
}
