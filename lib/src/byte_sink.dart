import 'dart:async';
import 'dart:typed_data';

/// Gathers small writes into one buffer before handing them to the real sink.
///
/// The encoder produces bytes in tiny pieces — a 255-byte LZW sub-block, an
/// eight-byte control block — and passing each straight through cost one sink
/// call and one allocation apiece: **24,365 of them** for a 5.8 MB animation,
/// measured. Batching into a fixed staging buffer makes that a few dozen, and
/// costs one buffer that never grows.
///
/// This does **not** weaken the streaming guarantee. The buffer is a fixed
/// [capacity], flushed whenever it fills and again at the end of every frame, so
/// what is held is bounded by that constant rather than by the animation's
/// length — which is the whole promise. A frame's bytes still leave before the
/// next frame is encoded.
final class BufferedByteSink {
  BufferedByteSink(this._sink, {int capacity = 64 * 1024})
    : _buffer = Uint8List(capacity);

  final StreamSink<List<int>> _sink;
  final Uint8List _buffer;
  int _length = 0;

  /// Bytes handed to the underlying sink so far, for tests and benchmarks.
  int flushedBytes = 0;

  void addByte(int byte) {
    if (_length == _buffer.length) flush();
    _buffer[_length++] = byte;
  }

  /// Copies [bytes] in, flushing as needed.
  ///
  /// Copies rather than forwarding, deliberately: the caller's buffer is reused
  /// — the LZW sub-block is the same 255 bytes every time — and a sink that
  /// queues writes would otherwise see it change underneath.
  void add(List<int> bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      if (_length == _buffer.length) flush();
      final room = _buffer.length - _length;
      final take = bytes.length - offset < room ? bytes.length - offset : room;
      _buffer.setRange(_length, _length + take, bytes, offset);
      _length += take;
      offset += take;
    }
  }

  /// Pushes what is buffered to the sink. Safe to call when empty.
  void flush() {
    if (_length == 0) return;
    // `sublist` copies, which is required: the buffer is about to be reused and
    // the sink may hold the reference until it has written it.
    _sink.add(_buffer.sublist(0, _length));
    flushedBytes += _length;
    _length = 0;
  }

  Future<void> close() async {
    flush();
    await _sink.close();
  }
}
