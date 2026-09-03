import 'dart:typed_data';

import 'byte_sink.dart';

/// GIF's LZW code width never exceeds twelve bits; at 4096 codes the dictionary
/// is reset rather than widened.
const int _maxCodeWidth = 12;
const int _maxCodes = 1 << _maxCodeWidth;

/// Slots in the string table's hash.
///
/// **Prime, and deliberately far larger than the 4096 codes it holds.** Both
/// halves were measured, and both are easy to get wrong:
///
/// - *Prime*, because the probe below steps by a key-dependent displacement. That
///   only visits every slot if the step is coprime to the size, which a power of
///   two is not. Switching to 8192 with linear probing instead — the obvious
///   "round number is faster" change — clustered so badly it ran **36 times
///   slower**, 0.7 Mpx/s against 26.
/// - *Large*, because the classic 5003 the original UNIX `compress` used puts the
///   load factor at 0.82, where open addressing probes several times per pixel.
///   At 9973 it is 0.41 and throughput rose about 20%. Past this it plateaus and
///   then falls: 12983 and 16381 measured no better, and 24593 measured worse,
///   because clearing a bigger table between frames costs more than the probes it
///   saves.
///
/// The cost is 78 kB of `Int32List`, allocated once for the whole animation.
const int _hashSize = 9973;

/// Compresses frames into GIF image-data sections.
///
/// Reused across every frame of an animation, which is the point: the string
/// table and the hash are allocated once and cleared
/// between frames. Allocating them per frame — as a straightforward
/// implementation does — costs 40 kB of garbage per frame and shows up as
/// collection pauses in the middle of a capture.
final class GifLzwEncoder {
  GifLzwEncoder()
    : _hashKeys = Int32List(_hashSize),
      _hashCodes = Int32List(_hashSize);

  /// `key + 1` per slot, so a plain zero means "empty" and the table can be
  /// cleared with a single `fillRange` rather than a loop of sentinels.
  final Int32List _hashKeys;
  final Int32List _hashCodes;

  /// Where the sub-block being filled starts in the staging buffer.
  ///
  /// The bytes go **straight into the sink's buffer** rather than through a
  /// scratch array of our own: the length byte is reserved first and patched
  /// once the block is done. Building each block separately and copying it over
  /// costs a full `memcpy` of the entire compressed output, which for a 5.8 MB
  /// animation is 5.8 MB of pointless copying.
  int _blockStart = -1;
  int _bitBuffer = 0;
  int _bitCount = 0;
  late BufferedByteSink _out;
  late int _minCodeSize;
  int _codeWidth = 0;
  int _nextCode = 0;
  int _clearCode = 0;
  int _endCode = 0;

  /// Writes a complete image-data section for [indices]: the minimum-code-size
  /// byte, the LZW sub-block stream, and the terminating zero-length block.
  ///
  /// [minCodeSize] is the bit width the palette needs, at least 2. GIF has no
  /// one-bit code size even for a two-colour table.
  void encode({
    required Uint8List indices,
    required int minCodeSize,
    required BufferedByteSink out,
  }) {
    assert(minCodeSize >= 2 && minCodeSize <= 8);
    _out = out;
    _minCodeSize = minCodeSize;
    _clearCode = 1 << minCodeSize;
    _endCode = _clearCode + 1;
    _blockStart = -1;
    _bitBuffer = 0;
    _bitCount = 0;

    out.addByte(minCodeSize);
    _resetTable();
    _writeCode(_clearCode);

    if (indices.isNotEmpty) {
      var prefix = indices[0];
      for (var i = 1; i < indices.length; i++) {
        final pixel = indices[i];
        // The key packs prefix and pixel into twenty bits, which stays an
        // integer on the web where bitwise operations are 32-bit.
        final key = (pixel << _maxCodeWidth) | prefix;

        // Open addressing with a displacement that depends on the key, which
        // spreads collisions far better than linear probing on this data: GIF
        // keys cluster hard, because consecutive pixels share a prefix.
        var slot = (pixel << 4) ^ prefix;
        final displacement = slot == 0 ? 1 : _hashSize - slot;
        var found = false;
        while (true) {
          final entry = _hashKeys[slot];
          if (entry == key + 1) {
            prefix = _hashCodes[slot];
            found = true;
            break;
          }
          if (entry == 0) break; // empty slot: not present, insert here
          slot -= displacement;
          if (slot < 0) slot += _hashSize;
        }
        if (found) continue;

        _writeCode(prefix);
        if (_nextCode < _maxCodes) {
          _hashKeys[slot] = key + 1;
          _hashCodes[slot] = _nextCode;
          _nextCode++;
          if (_nextCode > (1 << _codeWidth) && _codeWidth < _maxCodeWidth) {
            // Widen when the *next* code will not fit. A decoder widens on the
            // same count, so being one code early or late desynchronises the
            // entire stream — the classic way to get an image that decodes as
            // noise after the first few hundred pixels.
            _codeWidth++;
          }
        } else {
          // Full. Start again rather than widen past twelve bits.
          _writeCode(_clearCode);
          _resetTable();
        }
        prefix = pixel;
      }
      _writeCode(prefix);
    }

    _writeCode(_endCode);
    if (_bitCount > 0) _pushByte(_bitBuffer & 0xFF);
    _flushBlock();
    out.addByte(0); // the block stream's terminator
  }

  void _resetTable() {
    _hashKeys.fillRange(0, _hashSize, 0);
    _codeWidth = _minCodeSize + 1;
    _nextCode = _endCode + 1;
  }

  void _flushBlock() {
    if (_blockStart < 0) return;
    if (_out.length - _blockStart - 1 == 0) {
      // Nothing was written into it. The reserved length byte would encode an
      // empty block, which is the *terminator* — writing one here would end the
      // image early and truncate the frame.
      _out.rewindTo(_blockStart);
    } else {
      _out.endBlock(_blockStart);
    }
    _blockStart = -1;
  }

  void _pushByte(int byte) {
    if (_blockStart < 0) _blockStart = _out.beginBlock();
    _out.addByte(byte);
    if (_out.blockIsFull(_blockStart)) {
      _out.endBlock(_blockStart);
      _blockStart = -1;
    }
  }

  /// Codes are packed least-significant-bit first. The buffer holds at most
  /// seven leftover bits plus one twelve-bit code, so it stays under 32 bits and
  /// is safe on the web.
  void _writeCode(int code) {
    _bitBuffer |= code << _bitCount;
    _bitCount += _codeWidth;
    while (_bitCount >= 8) {
      _pushByte(_bitBuffer & 0xFF);
      _bitBuffer >>= 8;
      _bitCount -= 8;
    }
  }
}

/// The bit width a table of [colorCount] entries needs, as GIF counts it.
///
/// Two is the floor even for a one- or two-colour table: the format has no
/// one-bit code size.
int gifMinCodeSize({required int colorCount}) {
  var bits = 2;
  while ((1 << bits) < colorCount) {
    bits++;
  }
  return bits;
}
