import 'dart:typed_data';

import 'byte_sink.dart';

/// The largest a GIF sub-block may be. The length prefix is one byte, and 0
/// means "end of the block stream", so 255 is the ceiling.
const int _maxSubBlock = 255;

/// GIF's LZW code width never exceeds twelve bits; at 4096 codes the dictionary
/// is reset rather than widened.
const int _maxCodeWidth = 12;
const int _maxCodes = 1 << _maxCodeWidth;

/// Slots in the string table's hash. A prime comfortably above 4096 keeps the
/// load factor under 0.82, where open addressing still probes about twice on
/// average. The number is the one the original UNIX `compress` used, for the
/// same reason.
const int _hashSize = 5003;

/// Compresses frames into GIF image-data sections.
///
/// Reused across every frame of an animation, which is the point: the string
/// table, the sub-block buffer and the hash are allocated once and cleared
/// between frames. Allocating them per frame — as a straightforward
/// implementation does — costs 40 kB of garbage per frame and shows up as
/// collection pauses in the middle of a capture.
final class GifLzwEncoder {
  GifLzwEncoder()
    : _hashKeys = Int32List(_hashSize),
      _hashCodes = Int32List(_hashSize),
      _block = Uint8List(_maxSubBlock);

  /// `key + 1` per slot, so a plain zero means "empty" and the table can be
  /// cleared with a single `fillRange` rather than a loop of sentinels.
  final Int32List _hashKeys;
  final Int32List _hashCodes;

  /// The sub-block under construction. Never handed out — [BufferedByteSink]
  /// copies — so it is safe to reuse for the whole animation.
  final Uint8List _block;

  int _blockLength = 0;
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
    _blockLength = 0;
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
    if (_blockLength == 0) return;
    _out.addByte(_blockLength);
    // A view, not a copy: `add` copies into its own buffer, so nothing outlives
    // this call and the 255 bytes are never allocated again.
    _out.add(Uint8List.sublistView(_block, 0, _blockLength));
    _blockLength = 0;
  }

  void _pushByte(int byte) {
    _block[_blockLength++] = byte;
    if (_blockLength == _maxSubBlock) _flushBlock();
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
