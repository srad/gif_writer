import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

import 'round_trip_test.dart' show RecordingSink;

/// What the writer refuses, and why the refusal survived being optimised.
///
/// The per-pixel range check is the one piece of input validation here, and it
/// matters more than it looks: an index past the end of the colour table does
/// not fail, it decodes as **a different colour**. A file that is quietly wrong
/// is worse than one that will not open.
///
/// It is also on the hot path — a whole extra pass over every pixel — so it was
/// rewritten to OR the bytes together and only walk precisely when that suggests
/// trouble. These tests exist because that rewrite can go wrong in a way nothing
/// else here would notice: the OR **overstates** the maximum (1 and 2 combine to
/// look like 3), so a careless version rejects perfectly good frames.
void main() {
  GifWriter writerFor({required int colours, int side = 4}) => GifWriter(
    RecordingSink(),
    width: side,
    height: side,
    colors: GifColorTable.packed(<int>[
      for (var i = 0; i < colours; i++) i * 0x010101,
    ]),
  );

  Uint8List frame(List<int> pixels) => Uint8List.fromList(pixels);

  test('an index past the end of the table is refused', () async {
    final gif = writerFor(colours: 4);
    await expectLater(
      gif.addIndexedFrame(
        frame(<int>[
          0, 1, 2, 3, //
          0, 1, 2, 3,
          0, 1, 2, 9, // 9 is not a colour
          0, 1, 2, 3,
        ]),
      ),
      throwsArgumentError,
    );
  });

  test('the message names the offending pixel, not just the frame', () async {
    // A frame is thousands of pixels; "one of them is wrong" is not a bug
    // report. The precise pass exists to answer *which*.
    final gif = writerFor(colours: 4);
    await expectLater(
      gif.addIndexedFrame(
        frame(<int>[
          0, 1, 2, 3, //
          0, 1, 2, 3,
          0, 1, 2, 3,
          0, 1, 7, 3,
        ]),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('14'), contains('7')),
        ),
      ),
    );
  });

  group('indices that only *look* out of range are accepted', () {
    // The trap in the fast path. Bits from different pixels combine, so a frame
    // of 1s and 2s ORs to 3 — which is at the limit of a three-colour table even
    // though no single pixel is. A version that threw on the OR alone would
    // reject this, and the failure would look like "the library is broken" on
    // perfectly ordinary input.
    for (final (name, colours, pixels) in <(String, int, List<int>)>[
      ('1 and 2 OR to 3, with a 3-colour table', 3, <int>[1, 2, 1, 2]),
      ('1 and 4 OR to 5, with a 5-colour table', 5, <int>[1, 4, 4, 1]),
      ('2 and 5 OR to 7, with a 7-colour table', 7, <int>[2, 5, 5, 2]),
      ('3 and 4 OR to 7, with a 6-colour table', 6, <int>[3, 4, 4, 3]),
    ]) {
      test(name, () async {
        final gif = writerFor(colours: colours, side: 2);
        await gif.addIndexedFrame(frame(pixels));
        expect(gif.frameCount, 1);
        await gif.close();
      });
    }
  });

  test('a full table accepts every byte, including 255', () async {
    // With 256 colours the check is skipped entirely, because no byte can be out
    // of range. This is the case that would silently stop validating anything if
    // the skip were ever widened.
    final gif = GifWriter(
      RecordingSink(),
      width: 16,
      height: 16,
      colors: GifColorTable.packed(<int>[
        for (var i = 0; i < 256; i++) (i << 16) | (i << 8) | i,
      ]),
    );
    await gif.addIndexedFrame(
      Uint8List.fromList(<int>[for (var i = 0; i < 256; i++) i]),
    );
    expect(gif.frameCount, 1);
    await gif.close();
  });

  test('a frame of the wrong size is refused', () async {
    final gif = writerFor(colours: 4);
    await expectLater(
      gif.addIndexedFrame(frame(<int>[0, 1, 2])),
      throwsArgumentError,
    );
  });

  test('adding after close is refused', () async {
    final gif = writerFor(colours: 4);
    await gif.close();
    await expectLater(
      gif.addIndexedFrame(frame(List<int>.filled(16, 0))),
      throwsStateError,
    );
  });

  test('impossible dimensions are refused at construction', () {
    expect(
      () => GifWriter(
        RecordingSink(),
        width: 0,
        height: 4,
        colors: GifColorTable.packed(<int>[0, 0xFFFFFF]),
      ),
      throwsArgumentError,
    );
    expect(
      () => GifWriter(
        RecordingSink(),
        width: 4,
        height: 70000,
        colors: GifColorTable.packed(<int>[0, 0xFFFFFF]),
      ),
      throwsArgumentError,
    );
  });
}
