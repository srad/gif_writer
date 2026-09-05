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
///   measured 86.8 Mpx/s on a gradient against the 142.9 of the power-of-two
///   table that replaced it — both under the JIT of the day, before the sizing
///   below was redone AOT.
///
/// What wins is a power of two with a *mixing* hash and an **odd** displacement.
/// Odd is coprime to a power of two, so the probe still visits every slot — the
/// single property the prime was bought for — with no division anywhere.
///
/// *Large*, because the classic 5003 the original UNIX `compress` used puts the
/// load factor at 0.82, where open addressing probes several times per pixel; at
/// 32768 it is 0.125. The four powers of two around it were measured together,
/// AOT and interleaved for the historical 0.3.1 sizing experiment below. These
/// rates are not the current release benchmark; see doc/encoding-review.md.
///
/// | slots | memory | noise | photo | gradient |
/// | ---: | ---: | ---: | ---: | ---: |
/// | 8192 | 64 kB | 51.3 | 76.3 | 152.7 |
/// | 16384 | 128 kB | 59.5 | 88.1 | 158.1 |
/// | **32768** | **256 kB** | **64.4** | **94.1** | **156.3** |
/// | 65536 | 512 kB | 63.9 | 93.3 | 170.4 |
///
/// **32768 wins the two workloads that matter, and 65536 does not.** Noise is
/// LZW's worst case and the truest test of the hash: it peaks at 32768 and falls
/// back at 65536, where 512 kB of table no longer sits comfortably in cache.
/// Photo, representative content, peaks at 32768 too. Only the gradient prefers a
/// larger table — and the gradient is best case, long runs that barely touch the
/// hash at all, so its column is the noisiest here and the least worth sizing for.
///
/// This overturns the earlier finding that 16384 was the top of the curve. That
/// was measured when every reset **zeroed** the table, so doubling the table
/// doubled a clear that ran ten to seventeen times a frame and cancelled the
/// shorter probes. Epoch stamping (see [_hashKeys]) made clearing nearly free,
/// and once it is, 32768 wins outright. The only remaining cost of the larger
/// table is its 256 kB of `Int32List`, paid once for the whole animation rather
/// than per frame; the package's held memory rises from 0.19 MB to 0.31 MB with
/// it. These are buffer-size estimates; awaited streaming also retains small
/// runtime objects, while queued calls retain their inputs.
const int _hashSize = 32768;
const int _hashMask = _hashSize - 1;

/// Where the epoch sits in a slot, above the 21 bits `key + 1` needs.
const int _epochShift = 21;

/// One past the last usable epoch. At 1023 the largest slot value is
/// `(1023 << 21) + 2^20` = 2,146,435,072, inside `Int32List`'s positive range —
/// which is the property that keeps this exact on the web as well as the VM.
const int _maxEpoch = 1023;

/// Compresses frames into GIF image-data sections.
///
/// Reused across every frame of an animation, which is the point: the string
/// tables are allocated once. Dictionary entries are retired by generation
/// between frames; storage is cleared only when the generation counter wraps.
final class GifLzwEncoder {
  GifLzwEncoder()
    : _hashKeys = Int32List(_hashSize),
      _hashCodes = Int32List(_hashSize);

  /// `(epoch << 21) | (key + 1)` per slot, so the table is **retired rather
  /// than cleared**: bumping [_epoch] makes every existing entry test as empty
  /// without touching memory.
  ///
  /// The dictionary is reset far more often than once per frame — it also
  /// resets whenever the 4096 codes run out — and measured at 256x256 that is
  /// 10 resets a frame on noise at 32 colours and 17 at 256. Each `fillRange`
  /// of this table costs 13.6 us, which was 11% of a noise frame spent zeroing
  /// memory nobody was going to read.
  ///
  /// `key + 1` needs 21 bits (`key` is under 2^20, see [encode]), leaving ten
  /// for the epoch: 1023 generations before it has to recycle, which at the
  /// worst measured rate is one real clear per sixty frames.
  final Int32List _hashKeys;
  final Int32List _hashCodes;

  /// Which generation of the string table [_hashKeys] currently holds. Never
  /// zero, so a freshly allocated — all-zero — table reads as retired.
  int _epoch = 1;

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
    // Reassigned wherever `_resetTable` is called again, including inside the
    // loop below — see the warning on that method.
    var base = _resetTable();
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
        // then 1.0 rather than 0.125 and the probe below walks a long way.
        //
        // Shifting the key down by six folds `pixel` — which lives in bits 12
        // and up — into the low bits alongside `prefix`, so every slot is
        // reachable at every palette size. Measured on the three benchmark
        // workloads, against that classic hash, both under the JIT of the day:
        // 27.2 to 59.7 Mpx/s on noise, and 135.9 to 142.9 on a gradient.
        var slot = (key ^ (key >> 6)) & _hashMask;
        // Open addressing with a key-dependent displacement, which beats linear
        // probing badly here: consecutive pixels share a prefix, so keys arrive
        // in clusters. Forced odd, so it is coprime to a power-of-two table and
        // the probe still visits every slot.
        final displacement = ((key >> 3) | 1) & _hashMask;
        // Stamped with the current generation, and hoisted: the old code
        // recomputed `key + 1` on every probe iteration, so carrying the epoch
        // costs nothing per probe and one add per pixel.
        final want = base + key + 1;
        var found = false;
        while (true) {
          final entry = _hashKeys[slot];
          if (entry == want) {
            prefix = _hashCodes[slot];
            found = true;
            break;
          }
          // Anything below the current base belongs to a retired generation, or
          // is the zero of a never-used slot. Either way it is free to take, and
          // this is the same single comparison `entry == 0` used to be.
          if (entry < base) break;
          slot = (slot + displacement) & _hashMask;
        }
        if (found) continue;

        _writeCode(prefix);
        if (_nextCode < _maxCodes) {
          _hashKeys[slot] = want;
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
          // Full. Start again rather than widen past twelve bits. The clear
          // code goes out at the *old* width, before the reset changes it.
          _writeCode(_clearCode);
          base = _resetTable();
        }
        prefix = pixel;
      }
      _writeCode(prefix);
      // The decoder adds its last dictionary entry after reading this prefix.
      // It can therefore widen before EOI even though we insert no more keys.
      if (_nextCode == (1 << _codeWidth) && _codeWidth < _maxCodeWidth) {
        _codeWidth++;
      }
    }

    _writeCode(_endCode);
    if (_bitCount > 0) _pushByte(_bitBuffer & 0xFF);
    _flushBlock();
    out.addByte(0); // the block stream's terminator
  }

  /// Retires the string table and returns the new epoch base.
  ///
  /// **Callers must use the returned value**, not one cached from earlier: this
  /// is called from inside [encode]'s pixel loop whenever the dictionary fills,
  /// so a base hoisted above that loop goes stale mid-frame and every probe
  /// after it reads the wrong generation — a corrupt stream with nothing thrown.
  int _resetTable() {
    if (_epoch >= _maxEpoch) {
      // Recycled. This is the only place the table is actually zeroed, and it
      // is also exactly what every reset used to do.
      _hashKeys.fillRange(0, _hashSize, 0);
      _epoch = 1;
    } else {
      _epoch++;
    }
    _codeWidth = _minCodeSize + 1;
    _nextCode = _endCode + 1;
    return _epoch << _epochShift;
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
///
/// **Not the same floor as `GifColorTable.bitsPerPixel`, which is 1.** That one
/// sizes the colour table written into the header and a two-entry table is
/// legal; this one sizes the LZW codes and a one-bit code size is not. They look
/// like the same log2 and are two different rules — making them agree breaks the
/// file.
int gifMinCodeSize({required int colorCount}) {
  var bits = 2;
  while ((1 << bits) < colorCount) {
    bits++;
  }
  return bits;
}
