import 'dart:async';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'round_trip_test.dart' show RecordingSink;

/// The promise the package is named for, asserted rather than assumed.
///
/// Every other GIF encoder available in Dart builds the finished file in memory
/// and yields it at the end. If this one ever does the same, nothing about its
/// output changes — the file is still correct, the round-trip tests still pass,
/// and the only symptom is an out-of-memory crash on somebody's phone months
/// later. These tests are the only thing standing between that and a release.
///
/// **A "peak memory does not grow with length" test is deliberately absent.**
/// `ProcessInfo.currentRss` is GC-dependent and would be flaky, and a flaky test
/// guarding the one property that matters is worse than none. The two below are
/// deterministic and prove the same thing structurally: bytes already handed to
/// the sink cannot also be held.
void main() {
  GifColorTable twoColours() =>
      GifColorTable.packed(<int>[0x000000, 0xFFFFFF]);

  GifColorTable grays(int count) => GifColorTable.packed(<int>[
    for (var i = 0; i < count; i++) (i * 255 ~/ (count - 1)) * 0x010101,
  ]);

  Uint8List checkerboard({required int side, required int phase}) =>
      Uint8List.fromList(<int>[
        for (var i = 0; i < side * side; i++) (i + phase) % 2,
      ]);

  test('bytes reach the sink before close is called', () async {
    const side = 32;
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: side,
      height: side,
      colors: twoColours(),
    );

    for (var f = 0; f < 10; f++) {
      await gif.addIndexedFrame(checkerboard(side: side, phase: f));
    }

    expect(
      sink.length,
      greaterThan(0),
      reason:
          'nothing had been written after ten frames, so the encoder is '
          'accumulating and will hand the whole file over at close',
    );
    expect(sink.closed, isFalse, reason: 'the test has not closed it yet');

    await gif.close();
  });

  test('every frame writes its own image data, and nothing rewinds', () async {
    // The stronger half, and it has to be stronger than "the total grew".
    //
    // A first version asserted only `length > previous`, and a deliberate
    // tamper — buffering the LZW output while still emitting the per-frame
    // block headers — **passed it**. Eighteen bytes of graphic-control and image
    // descriptor per frame were enough to satisfy "it grew" while every byte of
    // actual picture sat in a list waiting for `close`. So the bar is the image
    // data itself: a 96x96 frame of noise compresses to well over a kilobyte,
    // which block headers cannot fake.
    const side = 96;
    const headerOverheadPerFrame = 18;
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: side,
      height: side,
      colors: grays(16),
    );

    Uint8List noise(int phase) => Uint8List.fromList(<int>[
      for (var i = 0; i < side * side; i++) (i * 7 + i ~/ 5 + phase) % 16,
    ]);

    final lengthAfterFrame = <int>[];
    Uint8List? prefixAfterFirst;
    for (var f = 0; f < 8; f++) {
      await gif.addIndexedFrame(noise(f));
      lengthAfterFrame.add(sink.length);
      prefixAfterFirst ??= sink.result;
    }

    for (var f = 1; f < lengthAfterFrame.length; f++) {
      final added = lengthAfterFrame[f] - lengthAfterFrame[f - 1];
      expect(
        added,
        greaterThan(headerOverheadPerFrame * 10),
        reason:
            'frame $f added only $added bytes — enough for its block headers '
            'but not its pixels, so the image data is being buffered',
      );
    }

    // Nothing already written is revisited: what the sink held after frame one
    // is still, byte for byte, the start of the file.
    final finalBytes = sink.result;
    expect(
      finalBytes.sublist(0, prefixAfterFirst!.length),
      prefixAfterFirst,
      reason: 'earlier bytes changed, so the writer is buffering and rewriting',
    );

    await gif.close();
  });

  test('back-pressure is applied once per frame, and on close', () async {
    // Without this the buffering simply moves into the sink, where it is the
    // same memory and far harder to notice. `GifWriter.toFile` wires this to
    // `IOSink.flush`, which completes when the OS has taken the bytes.
    var flushes = 0;
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: 8,
      height: 8,
      colors: twoColours(),
      onFlush: () async => flushes++,
    );

    for (var f = 0; f < 5; f++) {
      await gif.addIndexedFrame(checkerboard(side: 8, phase: f));
    }
    expect(flushes, 5, reason: 'a frame went out without waiting for the sink');

    await gif.close();
    expect(flushes, 6, reason: 'the trailer went out without a final flush');
  });

  test('small writes are batched, not passed straight through', () async {
    // An efficiency property, pinned because it is invisible in the output: the
    // file is byte-identical either way. Handing every 255-byte LZW sub-block
    // and every 8-byte control block to the sink individually cost **24,365**
    // sink calls for a 5.8 MB animation and half the throughput. Batching into
    // the staging buffer makes it one write per frame.
    //
    // The bound is per frame rather than an absolute count, so it holds however
    // many frames the test uses, and it allows a second write for a frame whose
    // compressed data overflows the buffer.
    const side = 32;
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: side,
      height: side,
      colors: grays(16),
    );

    const frames = 20;
    for (var f = 0; f < frames; f++) {
      await gif.addIndexedFrame(
        Uint8List.fromList(<int>[
          for (var i = 0; i < side * side; i++) (i * 3 + f) % 16,
        ]),
      );
    }
    await gif.close();

    expect(
      sink.lengthAfterEachAdd.length,
      lessThanOrEqualTo(frames * 2 + 2),
      reason:
          'the sink was written to ${sink.lengthAfterEachAdd.length} times for '
          '$frames frames — small writes are reaching it one at a time again',
    );
  });

  test('the staging buffer stays within the size it was given', () async {
    // The other half of batching: a buffer that grew to fit the animation would
    // pass every test above and quietly reintroduce the problem the package
    // exists to solve. A small buffer must produce *more* writes, not a bigger
    // buffer.
    // The frames have to be big enough to overflow the small buffer, or both
    // sizes flush once per frame and the comparison says nothing — which is
    // exactly what a first version of this test did, with 64x64 frames that
    // compressed to under 512 bytes.
    const side = 160;
    Future<int> writesWithBuffer(int bufferSize) async {
      final sink = RecordingSink();
      final gif = GifWriter(
        sink,
        width: side,
        height: side,
        colors: grays(16),
        bufferSize: bufferSize,
      );
      for (var f = 0; f < 4; f++) {
        await gif.addIndexedFrame(
          Uint8List.fromList(<int>[
            // Noise, so it does not compress away to nothing.
            for (var i = 0; i < side * side; i++) (i * 7 + i ~/ 3 + f) % 16,
          ]),
        );
      }
      await gif.close();
      return sink.lengthAfterEachAdd.length;
    }

    final tiny = await writesWithBuffer(512);
    final roomy = await writesWithBuffer(64 * 1024);
    expect(
      tiny,
      greaterThan(roomy),
      reason:
          'a 512-byte buffer produced no more writes than a 64 kB one, so the '
          'buffer is growing rather than flushing',
    );
  });

  test('a writer closed with no frames still produces a readable file', () async {
    // An empty stream is a legitimate input — a recording stopped before its
    // first capture — and throwing here would strand the caller with a
    // half-written file instead of an empty animation.
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: 4,
      height: 4,
      colors: twoColours(),
    );
    await gif.close();

    expect(sink.closed, isTrue);
    expect(gif.frameCount, 0);
    final bytes = sink.result;
    expect(bytes.sublist(0, 6), <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    expect(bytes.last, 0x3B, reason: 'no trailer');
  });

  test('a stream of frames pipes straight in', () async {
    // `GifWriter` is a `StreamConsumer`, which is the shape that lets a caller
    // hand over frames as they are produced without ever holding the list.
    const side = 16;
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: side,
      height: side,
      colors: twoColours(),
    );

    final frames = Stream<GifFrame>.fromIterable(<GifFrame>[
      for (var f = 0; f < 4; f++)
        GifFrame(
          indices: checkerboard(side: side, phase: f),
          delay: const Duration(milliseconds: 100),
        ),
    ]);

    await frames.pipe(gif);

    expect(gif.frameCount, 4);
    expect(sink.closed, isTrue, reason: 'pipe closes the consumer');
    final decoded = img.GifDecoder().decode(sink.result);
    expect(decoded?.frames, hasLength(4));
  });

  test('the delay lands in the file as hundredths', () async {
    // GIF has no finer unit. 40 ms is 4, and a viewer will honour it; anything
    // under 20 ms is a fiction the format cannot carry, which the API documents
    // rather than silently clamps.
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: 2,
      height: 2,
      colors: twoColours(),
    );
    await gif.addIndexedFrame(
      Uint8List.fromList(<int>[0, 1, 1, 0]),
      delay: const Duration(milliseconds: 40),
    );
    await gif.close();

    final bytes = sink.result;
    // The *pair*, not just the extension introducer: the Netscape looping block
    // is also a 0x21 and comes first, so searching for the introducer alone
    // finds the wrong one.
    var control = -1;
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x21 && bytes[i + 1] == 0xF9) {
        control = i;
        break;
      }
    }
    expect(control, isNonNegative, reason: 'no graphic control block');
    // Block size, packed field, then the delay: two bytes, little-endian.
    expect(bytes[control + 2], 0x04, reason: 'block size');
    expect(bytes[control + 4] | (bytes[control + 5] << 8), 4);
  });
}
