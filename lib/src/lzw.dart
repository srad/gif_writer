import 'dart:typed_data';

import 'byte_sink.dart';

/// GIF's LZW code width never exceeds twelve bits; at 4096 codes the dictionary
/// is reset rather than widened.
const int _maxCodeWidth = 12;
const int _maxCodes = 1 << _maxCodeWidth;

/// Slots in the string table's hash.
///
/// **A power of two, deliberately far larger than the 4096 codes it holds.**
/// Getting here took three attempts, and the two dead ends are worth recording,
/// because each looked obviously right and one of them held for weeks:
///
/// - **8192 with *linear* probing** ran **36 times slower** — 0.7 Mpx/s against
///   26. GIF keys cluster hard, because consecutive pixels share a prefix, and
///   linear probing turns clustering into long walks. That is what a power of two
///   costs when the probe is naive, and it is why this table was prime for a
///   while.
/// - **9973, prime, addressed with `key % _hashSize`.** Correct, and far better
///   than the broken hash it replaced, but a division per pixel is expensive
///   exactly where runs are long and the first probe already succeeds: it
///   measured 86.8 Mpx/s on a gradient against 142.9 for what is here now.
///
/// What wins is a power of two with a *mixing* hash and an **odd** displacement.
/// Odd is coprime to a power of two, so the probe still visits every slot — the
/// single property the prime was bought for — with no division anywhere.
///
/// *Large*, because the classic 5003 the original UNIX `compress` used puts the
/// load factor at 0.82, where open addressing probes several times per pixel; at
/// 16384 it is 0.25. This is the top of the curve, and both neighbours were
/// measured on the three benchmark workloads:
///
/// | slots | memory | noise | photo | gradient |
/// | ---: | ---: | ---: | ---: | ---: |
/// | 8192 | 64 kB | 51.6 | 75.4 | 132.0 |
/// | **16384** | **128 kB** | **59.7** | **89.5** | **142.9** |
/// | 32768 | 256 kB | 60.9 | 88.2 | 137.0 |
///
/// Doubling again buys nothing — clearing a bigger table between frames costs
/// about what the shorter probes save — so 128 kB of `Int32List` is the price,
/// allocated once for the whole animation rather than per frame.
const int _hashSize = 16384;
const int _hashMask = _hashSize - 1;

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

        // **Both halves of the key must reach the whole table.** The hash the
        // classic C implementations use is `(pixel << 4) ^ prefix`, and it is
        // quietly broken for small palettes: with 32 colours `pixel << 4` never
        // exceeds 496, so the xor never exceeds 4095 and **only 4096 slots can
        // ever be addressed, whatever the table's size**. The load factor is
        // then 1.0 rather than 0.25 and the probe below walks a long way.
        //
        // Shifting the key down by six folds `pixel` — which lives in bits 12
        // and up — into the low bits alongside `prefix`, so every slot is
        // reachable at every palette size. Measured on the three benchmark
        // workloads, against that classic hash: 27.2 to 59.7 Mpx/s on noise,
        // and 135.9 to 142.9 on a gradient.
        var slot = (key ^ (key >> 6)) & _hashMask;
        // Open addressing with a key-dependent displacement, which beats linear
        // probing badly here: consecutive pixels share a prefix, so keys arrive
        // in clusters. Forced odd, so it is coprime to a power-of-two table and
        // the probe still visits every slot.
        final displacement = ((key >> 3) | 1) & _hashMask;
        var found = false;
        while (true) {
          final entry = _hashKeys[slot];
          if (entry == key + 1) {
            prefix = _hashCodes[slot];
            found = true;
            break;
          }
          if (entry == 0) break; // empty slot: not present, insert here
          slot = (slot + displacement) & _hashMask;
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
