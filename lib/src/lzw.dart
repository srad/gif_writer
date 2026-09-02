import 'dart:typed_data';

/// The largest a GIF sub-block may be. The length prefix is one byte, and 0
/// means "end of the block stream", so 255 is the ceiling.
const int _maxSubBlock = 255;

/// GIF's LZW code width never exceeds twelve bits; at 4096 codes the dictionary
/// is reset rather than widened.
const int _maxCodeWidth = 12;
const int _maxCodes = 1 << _maxCodeWidth;

/// Compresses [indices] and emits a complete GIF **image data** section:
/// the minimum-code-size byte, the LZW sub-block stream, and the terminating
/// zero-length block.
///
/// Output goes out through [emit] as it is produced — at most one 255-byte
/// sub-block is held at a time — so a frame's compressed bytes are never
/// accumulated in full. That is the property the whole package exists for; see
/// `writer.dart`.
///
/// [minCodeSize] is the bit width the palette needs, at least 2. GIF forbids 1
/// even for a two-colour table.
void gifLzwCompress({
  required Uint8List indices,
  required int minCodeSize,
  required void Function(List<int> bytes) emit,
}) {
  assert(minCodeSize >= 2 && minCodeSize <= 8);

  final clearCode = 1 << minCodeSize;
  final endCode = clearCode + 1;

  // One byte of header, then the sub-block stream.
  emit(<int>[minCodeSize]);

  final block = Uint8List(_maxSubBlock);
  var blockLength = 0;
  var bitBuffer = 0;
  var bitCount = 0;

  void flushBlock() {
    if (blockLength == 0) return;
    // Length prefix, then the data. Copied rather than viewed: `block` is
    // reused, and a view would alias bytes the caller may not have written yet.
    emit(<int>[blockLength, ...block.sublist(0, blockLength)]);
    blockLength = 0;
  }

  void pushByte(int byte) {
    block[blockLength++] = byte;
    if (blockLength == _maxSubBlock) flushBlock();
  }

  // Codes are packed least-significant-bit first. `bitBuffer` holds at most
  // 7 leftover bits plus one 12-bit code, so it stays under 32 bits and is safe
  // on the web, where `<<` is 32-bit.
  void writeCode(int code, int width) {
    bitBuffer |= code << bitCount;
    bitCount += width;
    while (bitCount >= 8) {
      pushByte(bitBuffer & 0xFF);
      bitBuffer >>= 8;
      bitCount -= 8;
    }
  }

  var codeWidth = minCodeSize + 1;
  var nextCode = endCode + 1;

  // Keyed on `(prefix << 8) | pixel`. The prefix is under 4096 and the pixel
  // under 256, so the key fits in twenty bits — small enough to stay an integer
  // on the web. Bounded at 4096 entries by the reset below, which is what keeps
  // a frame's dictionary from growing with its size.
  var dictionary = <int, int>{};

  if (indices.isEmpty) {
    // Still a legal image: the decoder needs the clear and end codes even with
    // no pixels between them.
    writeCode(clearCode, codeWidth);
    writeCode(endCode, codeWidth);
    if (bitCount > 0) pushByte(bitBuffer & 0xFF);
    flushBlock();
    emit(const <int>[0]);
    return;
  }

  writeCode(clearCode, codeWidth);

  var prefix = indices[0];
  for (var i = 1; i < indices.length; i++) {
    final pixel = indices[i];
    final key = (prefix << 8) | pixel;
    final existing = dictionary[key];
    if (existing != null) {
      prefix = existing;
      continue;
    }

    writeCode(prefix, codeWidth);
    dictionary[key] = nextCode;
    nextCode++;

    if (nextCode == _maxCodes) {
      // Full: start again rather than widen past twelve bits.
      writeCode(clearCode, codeWidth);
      dictionary = <int, int>{};
      codeWidth = minCodeSize + 1;
      nextCode = endCode + 1;
    } else if (nextCode > (1 << codeWidth)) {
      // The **next** code will not fit the current width. Widening here rather
      // than when a code is emitted is the classic off-by-one in this
      // algorithm: a decoder widens on the same count, so being a code early or
      // late desynchronises the whole stream.
      codeWidth++;
    }

    prefix = pixel;
  }

  writeCode(prefix, codeWidth);
  writeCode(endCode, codeWidth);
  if (bitCount > 0) pushByte(bitBuffer & 0xFF);
  flushBlock();
  // The block stream's terminator.
  emit(const <int>[0]);
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
