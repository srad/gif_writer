import 'dart:async';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

class ControlledSink implements StreamSink<List<int>> {
  final bytes = BytesBuilder();
  final completion = Completer<void>();
  Object? writeFailure;
  Object? closeFailure;
  bool completeOnClose = true;
  int writes = 0;
  int closes = 0;
  int doneReads = 0;

  @override
  void add(List<int> data) {
    writes++;
    if (writeFailure != null) throw writeFailure!;
    bytes.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      completion.completeError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    closes++;
    if (closeFailure != null) throw closeFailure!;
    if (completeOnClose && !completion.isCompleted) completion.complete();
  }

  @override
  Future<void> get done {
    doneReads++;
    return completion.future;
  }
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  final colors = GifColorTable.packed([0, 0xFF0000, 0x00FF00, 0x0000FF]);

  test('mixed frames wait for flushing; close drains them in order', () async {
    final sink = ControlledSink();
    final gate = Completer<void>();
    var flushes = 0;
    final gif = GifWriter(sink, width: 1, height: 1, colors: colors,
      onFlush: () => flushes++ == 0 ? gate.future : Future<void>.value());
    final frames = [
      gif.addIndexedFrame(Uint8List.fromList([1])),
      gif.addRgbFrame(Uint8List.fromList([0, 255, 0])),
      gif.addRgbaFrame(Uint8List.fromList([0, 0, 255, 255])),
    ];
    final closing = gif.close();
    expect(identical(closing, gif.close()), isTrue);
    var closed = false;
    unawaited(closing.then((_) => closed = true));
    await pump();
    expect(gif.frameCount, 1);
    expect(sink.writes, 1);
    expect(closed, isFalse);
    await expectLater(gif.addIndexedFrame(Uint8List(1)), throwsStateError);
    gate.complete();
    await Future.wait(frames);
    await closing;
    expect(sink.closes, 1);
    expect(sink.doneReads, 1);
    expect(flushes, 4);
    final decoded = img.GifDecoder().decode(sink.bytes.toBytes())!;
    expect(decoded.frames.map((f) {
      final p = f.getPixel(0, 0);
      return (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
    }), [0xFF0000, 0x00FF00, 0x0000FF]);
  });

  test('invalid input does not poison palette derivation or queued frames', () async {
    final sink = ControlledSink();
    final gif = GifWriter(sink, width: 1, height: 1);
    final missing = expectLater(gif.addIndexedFrame(Uint8List(1)), throwsStateError);
    final invalid = expectLater(gif.addRgbFrame(Uint8List(2)), throwsArgumentError);
    final rgb = gif.addRgbFrame(Uint8List.fromList([255, 0, 0]));
    final indexed = gif.addIndexedFrame(Uint8List(1));
    final badIndex = expectLater(
      gif.addIndexedFrame(Uint8List.fromList([255])), throwsArgumentError);
    await Future.wait([missing, invalid, rgb, indexed, badIndex]);
    expect(gif.frameCount, 2);
    await gif.close();
    expect(img.GifDecoder().decode(sink.bytes.toBytes())!.frames.length, 2);
  });

  test('an awaited input buffer can be reused', () async {
    final sink = ControlledSink();
    final gif = GifWriter(sink, width: 1, height: 1, colors: colors);
    final pixel = Uint8List.fromList([1]);
    await gif.addIndexedFrame(pixel);
    pixel[0] = 2;
    await gif.addIndexedFrame(pixel);
    await gif.close();
    final frames = img.GifDecoder().decode(sink.bytes.toBytes())!.frames;
    expect(frames[0].getPixel(0, 0).r, 255);
    expect(frames[1].getPixel(0, 0).g, 255);
  });

  for (final asynchronous in [false, true]) {
    test('a ${asynchronous ? 'flush' : 'write'} failure is terminal and closes once', () async {
      final failure = StateError('primary failure');
      final trace = StackTrace.fromString('original failure stack');
      final sink = ControlledSink()..closeFailure = StateError('cleanup failure');
      if (!asynchronous) sink.writeFailure = failure;
      final gif = GifWriter(sink, width: 1, height: 1, colors: colors,
        onFlush: asynchronous ? () => Future<void>.error(failure, trace) : null);
      final first = gif.addIndexedFrame(Uint8List(1));
      final second = gif.addIndexedFrame(Uint8List(1));
      final closing = gif.close();
      expect(identical(closing, gif.close()), isTrue);
      await Future.wait([
        expectLater(first, throwsA(same(failure))),
        expectLater(second, throwsA(same(failure))),
        expectLater(closing, throwsA(same(failure))),
      ]);
      expect(sink.writes, 1, reason: 'no retry or later frame may write');
      expect(sink.closes, 1);
      expect(identical(closing, gif.close()), isTrue);
      if (asynchronous) {
        try { await closing; } catch (_, stack) {
          expect(stack.toString(), contains('original failure stack'));
        }
      }
    });
  }

  test('an early done error is observed and stops pending frames', () async {
    final sink = ControlledSink();
    final gate = Completer<void>();
    final failure = StateError('connection reset');
    final gif = GifWriter(sink, width: 1, height: 1, colors: colors,
      onFlush: () => gate.future);
    final first = gif.addIndexedFrame(Uint8List(1));
    final next = gif.addIndexedFrame(Uint8List(1));
    final firstError = expectLater(first, throwsA(same(failure)));
    final nextError = expectLater(next, throwsA(same(failure)));
    await pump();
    sink.completion.completeError(failure);
    await pump(); // no sink-side suppression and no caller listening to done
    gate.complete();
    await Future.wait([firstError, nextError]);
    await expectLater(gif.close(), throwsA(same(failure)));
    await expectLater(gif.done, throwsA(same(failure)));
    expect(sink.writes, 1);
    expect(sink.closes, 1);
    expect(sink.doneReads, 1);
  });

  test('close flush failure still closes, including an empty writer', () async {
    final sink = ControlledSink();
    final failure = StateError('final flush failed');
    final gif = GifWriter(sink, width: 1, height: 1,
      onFlush: () => throw failure);
    await expectLater(gif.close(), throwsA(same(failure)));
    expect(sink.closes, 1);
    expect(sink.writes, 1);
  });

  test('close waits for done and forwards its failure', () async {
    final sink = ControlledSink()..completeOnClose = false;
    final gif = GifWriter(sink, width: 1, height: 1);
    final failure = StateError('late close error');
    final closing = gif.close();
    final expected = expectLater(closing, throwsA(same(failure)));
    await pump();
    expect(sink.closes, 1);
    sink.completion.completeError(failure);
    await expected;
  });

  test('streams have exclusive ownership, released after a source error', () async {
    final sink = ControlledSink();
    final gif = GifWriter(sink, width: 1, height: 1, colors: colors);
    final source = StreamController<GifFrame>();
    final failure = StateError('source failed');
    final consuming = expectLater(gif.addStream(source.stream), throwsA(same(failure)));
    await expectLater(gif.addStream(const Stream.empty()), throwsStateError);
    await expectLater(gif.addIndexedFrame(Uint8List(1)), throwsStateError);
    await expectLater(gif.close(), throwsStateError);
    source.addError(failure);
    await consuming;
    await source.close();
    await gif.addIndexedFrame(Uint8List(1));
    await gif.close();
    await expectLater(gif.addStream(const Stream.empty()), throwsStateError);
  });
}
