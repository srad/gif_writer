import 'dart:typed_data';

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
    return GifColorTable._(Uint8List.fromList(rgb), count);
  }

  /// Builds a table from packed `0xRRGGBB` values.
  factory GifColorTable.packed(List<int> colors) {
    final rgb = Uint8List(colors.length * 3);
    for (var i = 0; i < colors.length; i++) {
      rgb[i * 3] = (colors[i] >> 16) & 0xFF;
      rgb[i * 3 + 1] = (colors[i] >> 8) & 0xFF;
      rgb[i * 3 + 2] = colors[i] & 0xFF;
    }
    return GifColorTable.rgb(rgb);
  }

  GifColorTable._(this._rgb, this.length);

  final Uint8List _rgb;

  /// How many colours the caller supplied, before padding.
  final int length;

  /// The colour at [index], packed as `0xRRGGBB`.
  int operator [](int index) =>
      (_rgb[index * 3] << 16) | (_rgb[index * 3 + 1] << 8) | _rgb[index * 3 + 2];

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
