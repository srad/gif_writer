import 'dart:async';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

/// A sink that fails the way a socket does: `add` and `close` succeed, but the
/// failure is reported **out of band** through `done`. This is exactly the case
/// the per-frame flush cannot catch, and the reason `GifWriter.done` exists.
class _AsyncSink implements StreamSink<List<int>> {
  final Completer<void> _done = Completer<void>();

  _AsyncSink() {
    // The error below is the point of the test, but Dart reports an errored
    // future with no listener as uncaught and fails the run. Register a listener
    // here so the zone stays quiet; the assertions read `writer.done`/`close`,
    // which each attach their own listener and receive the same error.
    unawaited(_done.future.catchError((Object _) {}));
  }

  /// Complete `done` with an error, as a dropped connection would.
  void failDone(Object error) {
    if (!_done.isCompleted) _done.completeError(error);
  }

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future<void> close() async {
    // A clean sink resolves `done` at close; only `failDone` errors it first.
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

void main() {
  final table = GifColorTable.packed(<int>[0x000000, 0xFFFFFF]);
  Uint8List frame() => Uint8List(4); // 2x2, index 0 everywhere

  GifWriter writerOn(StreamSink<List<int>> sink) =>
      GifWriter(sink, width: 2, height: 2, colors: table);

  test(
    'a sink error reported through done surfaces from writer.done',
    () async {
      final sink = _AsyncSink();
      final gif = writerOn(sink);
      await gif.addIndexedFrame(frame());

      final failure = StateError('connection reset');
      sink.failDone(failure);

      await expectLater(gif.done, throwsA(same(failure)));
    },
  );

  test('and the same error also rejects close()', () async {
    final sink = _AsyncSink();
    final gif = writerOn(sink);
    await gif.addIndexedFrame(frame());

    final failure = StateError('connection reset');
    sink.failDone(failure);

    // close() closes the sink normally, then awaits `done` — so a caller who
    // only awaits close() still sees the out-of-band failure.
    await expectLater(gif.close(), throwsA(same(failure)));
  });

  test('a clean sink completes both done and close normally', () async {
    final sink = _AsyncSink();
    final gif = writerOn(sink);
    await gif.addIndexedFrame(frame());

    await gif.close();
    await gif.done; // resolved by close, completes without error
  });
}
