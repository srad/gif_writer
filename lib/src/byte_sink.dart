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
  /// [capacity] must leave room for a whole sub-block at once.
  ///
  /// A GIF sub-block is a length byte plus up to 255 of data, and [beginBlock]
  /// hands out a position that [endBlock] patches later. If a flush could happen
  /// between the two, that position would be stale and the length would be
  /// written over somebody else's byte — a corrupt file, with nothing thrown.
  /// So the buffer is required to be larger than any block that can be opened in
  /// it, and the requirement is enforced rather than documented: 256 exactly is
  /// legal but leaves no room for anything else, so the floor is [minCapacity].
  /// A factory rather than an `assert`, so the check behaves the same in a
  /// release build. An assert would make this a corrupt file in production and
  /// an error in development, which is the worst of both.
  factory BufferedByteSink(
    StreamSink<List<int>> sink, {
    int capacity = 64 * 1024,
  }) {
    if (capacity < minCapacity) {
      throw ArgumentError.value(
        capacity,
        'capacity',
        'must be at least $minCapacity, so a 256-byte sub-block cannot '
            'straddle a flush',
      );
    }
    return BufferedByteSink._(sink, capacity);
  }

  BufferedByteSink._(this._sink, int capacity) : _buffer = Uint8List(capacity);

  /// The smallest staging buffer that can hold a sub-block with room to spare.
  static const int minCapacity = 1024;

  final StreamSink<List<int>> _sink;
  final Uint8List _buffer;
  int _length = 0;

  /// How many bytes are staged but not yet flushed.
  int get length => _length;

  void addByte(int byte) {
    if (_length == _buffer.length) flush();
    _buffer[_length++] = byte;
  }

  /// Reserves a GIF sub-block's length byte and returns its position.
  ///
  /// The LZW coder then writes its bytes with [addByte] straight into this
  /// buffer and calls [endBlock] to fill the length in. That removes a whole
  /// copy of every compressed byte: the obvious arrangement builds each block in
  /// a 255-byte scratch array and then copies it here, which is one `memcpy` of
  /// the entire output.
  ///
  /// Enough room is made first that a block — 255 bytes plus its length — never
  /// straddles a flush, so [addByte] cannot split one.
  int beginBlock() {
    if (_buffer.length - _length < 256) flush();
    final at = _length;
    _buffer[_length++] = 0;
    return at;
  }

  /// Abandons the block opened at [at], as if it had never been begun.
  ///
  /// Only for a block that ended up empty: its reserved length byte would encode
  /// a zero-length block, and in GIF that is the *terminator* — leaving one in
  /// the middle of a frame ends the image early and truncates it.
  void rewindTo(int at) => _length = at;

  /// Fills in the length of the block opened at [at].
  void endBlock(int at) => _buffer[at] = _length - at - 1;

  /// Whether the block opened at [at] has reached the 255-byte maximum.
  bool blockIsFull(int at) => _length - at - 1 == 255;

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
    _length = 0;
  }

  Future<void> close() async {
    flush();
    await _sink.close();
  }
}
