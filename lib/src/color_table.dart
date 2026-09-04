import 'dart:typed_data';

import 'quantizer.dart';

/// A GIF colour table: up to 256 opaque RGB entries.
///
/// Deliberately **not** called `GifPalette`. Applications that also model a
/// palette of their own — the one this package was written for does — would
/// otherwise need a prefix on every use, and a published name cannot be taken
/// back.
class GifColorTable {
  /// Wraps [rgb], which must be three bytes per entry and at most 256 entries.
  ///
  /// The bytes are copied, so a caller reusing its buffer cannot change a table
  /// that has already been written into a file's header.
  factory GifColorTable.rgb(List<int> rgb) {
    if (rgb.length % 3 != 0) {
      throw ArgumentError.value(
        rgb.length,
        'rgb',
        'must be three bytes per colour',
      );
    }
    final count = rgb.length ~/ 3;
    if (count == 0 || count > 256) {
      throw ArgumentError.value(count, 'rgb', 'needs 1 to 256 colours');
    }
    // Checked rather than left to `Uint8List.fromList`, which silently keeps the
    // low eight bits: 300 becomes 44 and -1 becomes 255, a wrong colour in the
    // header with nothing thrown. The rest of this package refuses bad input
    // rather than writing a file that decodes to something the caller never gave.
    for (var i = 0; i < rgb.length; i++) {
      if (rgb[i] < 0 || rgb[i] > 255) {
        throw ArgumentError.value(
          rgb[i],
          'rgb[$i]',
          'each channel must be 0 to 255',
        );
      }
    }
    return GifColorTable._(Uint8List.fromList(rgb), count);
  }

  /// Builds a table from packed `0xRRGGBB` values.
  factory GifColorTable.packed(List<int> colors) {
    final rgb = Uint8List(colors.length * 3);
    for (var i = 0; i < colors.length; i++) {
      // Refused rather than masked with `& 0xFF`: an accidental alpha byte
      // (0xFF123456) or a negative would otherwise be dropped silently, and two
      // distinct inputs colliding to one 24-bit value would seed a duplicate
      // colour — which the ordered dither then has to treat as "no choice".
      if (colors[i] < 0 || colors[i] > 0xFFFFFF) {
        throw ArgumentError.value(
          colors[i],
          'colors[$i]',
          'must be a packed 0xRRGGBB value, 0 to 0xFFFFFF',
        );
      }
      rgb[i * 3] = (colors[i] >> 16) & 0xFF;
      rgb[i * 3 + 1] = (colors[i] >> 8) & 0xFF;
      rgb[i * 3 + 2] = colors[i] & 0xFF;
    }
    return GifColorTable.rgb(rgb);
  }

  /// Derives a table from raw pixels: [rgb] is three bytes per pixel, and the
  /// result holds at most [maxColors] entries chosen by [quantizer].
  ///
  /// This is the answer to "I have a photo, not a palette." Feed it a
  /// representative image — a single frame, or a montage of frames you sample —
  /// and hand the table to `GifWriter`. (`GifWriter` will also derive one for you
  /// from the first frame if you leave its `colors:` unset; this factory is for
  /// when you want to choose *what* is quantised, or reuse the table.)
  ///
  /// [maxColors] is clamped to GIF's ceiling of 256 by validation, not silently:
  /// the whole package refuses out-of-range input rather than writing a file that
  /// means something the caller did not ask for. See [GifQuantizer] for the
  /// octree-versus-Wu trade-off.
  factory GifColorTable.quantize(
    Uint8List rgb, {
    int maxColors = 256,
    GifQuantizer quantizer = GifQuantizer.octree,
  }) {
    if (rgb.length % 3 != 0) {
      throw ArgumentError.value(
        rgb.length,
        'rgb',
        'must be three bytes per pixel',
      );
    }
    if (rgb.isEmpty) {
      throw ArgumentError.value(rgb.length, 'rgb', 'needs at least one pixel');
    }
    if (maxColors < 1 || maxColors > 256) {
      throw ArgumentError.value(maxColors, 'maxColors', 'must be 1 to 256');
    }
    return GifColorTable.rgb(
      runQuantizer(quantizer: quantizer, rgb: rgb, maxColors: maxColors),
    );
  }

  GifColorTable._(this._rgb, this.length);

  final Uint8List _rgb;

  /// How many colours the caller supplied, before padding.
  final int length;

  /// The colour at [index], packed as `0xRRGGBB`.
  int operator [](int index) =>
      (_rgb[index * 3] << 16) |
      (_rgb[index * 3 + 1] << 8) |
      _rgb[index * 3 + 2];

  /// The table as GIF stores it: a power-of-two number of entries, zero-padded.
  ///
  /// The format has no way to say "five colours" — the size field is an
  /// exponent, so a table is always 2, 4, 8 … 256 entries long and the unused
  /// tail is black. Padding here rather than at the writer keeps the one place
  /// that knows this rule next to the one that knows the entry count.
  Uint8List toBytes() {
    final padded = 1 << bitsPerPixel;
    if (padded == length) return Uint8List.fromList(_rgb);
    final out = Uint8List(padded * 3);
    out.setRange(0, _rgb.length, _rgb);
    return out;
  }

  /// The exponent GIF writes in its size field: the table holds `2^bits`
  /// entries. Never below 1, because the smallest legal table is two colours.
  ///
  /// **Not the same floor as `gifMinCodeSize` in `lzw.dart`, which is 2.** The
  /// two are separate rules of the format that happen to share a shape: this one
  /// sizes the colour table, that one sizes the LZW codes, and GIF permits a
  /// two-entry table while forbidding a one-bit code size. Changing either to
  /// match the other desynchronises the stream from the header.
  int get bitsPerPixel {
    var bits = 1;
    while ((1 << bits) < length) {
      bits++;
    }
    return bits;
  }

  @override
  String toString() => 'GifColorTable($length colours)';
}
