import 'dart:typed_data';

import 'color_table.dart';

/// Bits per channel in the inverse colour cube's key.
///
/// Five is the usual choice and the reason is memory: six would be 262,144
/// cells rather than 32,768, and this package's whole claim is that its
/// overhead is small and fixed.
const int _cubeBits = 5;
const int _cubeSide = 1 << _cubeBits;
const int _cubeCells = _cubeSide * _cubeSide * _cubeSide;

/// Half a cell, for the representative colour a cell's entry is computed from.
const int _cellHalf = 1 << (7 - _cubeBits);

/// Slots in the exact-colour table. A power of two well above the 256 entries
/// it can hold, because a load factor near 1.0 has already cost this package
/// once — see the hash in `lzw.dart`.
const int _exactSlots = 1024;
const int _exactMask = _exactSlots - 1;

const int _flagFilled = 1;
const int _flagHasPaletteColour = 2;

/// Maps an RGB colour to the nearest entries of a [GifColorTable].
///
/// Built once per writer and reused for the whole animation. Nothing here is
/// cleared between frames: the answers depend only on the palette, which is
/// fixed for a writer's lifetime. **That changes the day per-frame palettes
/// arrive**, and this cache will then have to be invalidated alongside the LZW
/// table.
class ColorMapper {
  ColorMapper(GifColorTable colors)
    : _count = colors.length,
      _r = Uint8List(colors.length),
      _g = Uint8List(colors.length),
      _b = Uint8List(colors.length),
      _best = Uint8List(_cubeCells),
      _second = Uint8List(_cubeCells),
      _flags = Uint8List(_cubeCells),
      _exactKeys = Int32List(_exactSlots),
      _exactValues = Uint8List(_exactSlots) {
    for (var i = 0; i < _count; i++) {
      final rgb = colors[i];
      _r[i] = (rgb >> 16) & 0xFF;
      _g[i] = (rgb >> 8) & 0xFF;
      _b[i] = rgb & 0xFF;
      _insertExact(rgb: rgb, index: i);
      // Which cell this palette colour lives in. Only these cells ever consult
      // the exact table, so a photograph — whose pixels mostly land in cells
      // holding no palette colour at all — does not pay for a lookup that
      // cannot succeed.
      _flags[_cellOf(r: _r[i], g: _g[i], b: _b[i])] |= _flagHasPaletteColour;
    }
  }

  final int _count;
  final Uint8List _r;
  final Uint8List _g;
  final Uint8List _b;

  /// The inverse colour cube: for each 5:5:5 cell, the two nearest entries to
  /// that cell's centre. Filled lazily — an animation usually touches a small
  /// part of the colour space, and filling all 32,768 up front would cost more
  /// than it saves.
  final Uint8List _best;
  final Uint8List _second;
  final Uint8List _flags;

  /// The palette's own colours, so a pixel that is already exactly a palette
  /// colour maps to it rather than to whatever the cube's 5-bit cell suggests.
  ///
  /// `key + 1` per slot so zero means empty.
  final Int32List _exactKeys;
  final Uint8List _exactValues;

  /// How many colours the palette holds.
  int get length => _count;

  static int _cellOf({required int r, required int g, required int b}) =>
      ((r >> (8 - _cubeBits)) << (2 * _cubeBits)) |
      ((g >> (8 - _cubeBits)) << _cubeBits) |
      (b >> (8 - _cubeBits));

  /// Squared distance, **luma-weighted**.
  ///
  /// Plain Euclidean RGB treats a green error as no worse than a blue one, and
  /// the eye disagrees by a factor of about four. The weights are the classic
  /// 2:4:3. Squared throughout, so no `sqrt` reaches the hot loop — only the
  /// ordering matters and squaring preserves it.
  static int _distance({
    required int r1,
    required int g1,
    required int b1,
    required int r2,
    required int g2,
    required int b2,
  }) {
    final dr = r1 - r2;
    final dg = g1 - g2;
    final db = b1 - b2;
    return 2 * dr * dr + 4 * dg * dg + 3 * db * db;
  }

  /// A web-safe hash: xor-shifts only, so it never leaves 24 bits and cannot
  /// lose precision where `int` is a double. A multiply-based mixer would
  /// overflow 53 bits for a 24-bit key and quietly misbehave on the web.
  static int _exactSlot(int rgb) => (rgb ^ (rgb >> 11) ^ (rgb >> 21)) & _exactMask;

  void _insertExact({required int rgb, required int index}) {
    var slot = _exactSlot(rgb);
    final displacement = ((rgb >> 3) | 1) & _exactMask;
    while (_exactKeys[slot] != 0) {
      // Already present: the palette repeats a colour. Keep the **first**
      // index, because that is the one a caller reading the table top to bottom
      // would expect, and because a later duplicate is unreachable anyway.
      if (_exactKeys[slot] == rgb + 1) return;
      slot = (slot + displacement) & _exactMask;
    }
    _exactKeys[slot] = rgb + 1;
    _exactValues[slot] = index;
  }

  /// The palette index exactly equal to [rgb], or -1.
  int exactIndexOf(int rgb) {
    var slot = _exactSlot(rgb);
    final displacement = ((rgb >> 3) | 1) & _exactMask;
    while (true) {
      final key = _exactKeys[slot];
      if (key == 0) return -1;
      if (key == rgb + 1) return _exactValues[slot];
      slot = (slot + displacement) & _exactMask;
    }
  }

  /// The two nearest palette entries to a colour, packed as
  /// `best | (second << 8)`.
  ///
  /// **Packed rather than returned as a record or a pair of out-parameters**
  /// because this runs once per pixel; an allocation here would show up as
  /// collection pauses in the middle of a capture, which is the exact failure
  /// this package exists to avoid.
  ///
  /// When the palette holds one colour, or the colour is an exact palette
  /// match, both halves are the same index — which the dither reads as "no
  /// choice to make" and leaves alone.
  int candidates({required int r, required int g, required int b}) {
    final cell = _cellOf(r: r, g: g, b: b);
    var flags = _flags[cell];
    if (flags & _flagFilled == 0) {
      _fill(cell);
      flags = _flags[cell];
    }

    // Only where a palette colour actually lives in this cell can an exact
    // match beat the cube's answer, so the probe is skipped everywhere else.
    if (flags & _flagHasPaletteColour != 0) {
      final exact = exactIndexOf((r << 16) | (g << 8) | b);
      if (exact >= 0) return exact | (exact << 8);
    }

    return _best[cell] | (_second[cell] << 8);
  }

  /// The nearest palette entry, ignoring the second candidate.
  int nearest({required int r, required int g, required int b}) =>
      candidates(r: r, g: g, b: b) & 0xFF;

  /// Computes a cell's two nearest entries from its **centre**.
  ///
  /// The centre, not the query colour: that is what makes the cube a cache at
  /// all. It also means the answer is exact only for the centre — a query near
  /// a cell boundary can get a very slightly worse entry, which is the price of
  /// not scanning 256 colours per pixel and is measured in `tool/dither.dart`.
  void _fill(int cell) {
    final cr = ((cell >> (2 * _cubeBits)) << (8 - _cubeBits)) | _cellHalf;
    final cg = (((cell >> _cubeBits) & (_cubeSide - 1)) << (8 - _cubeBits)) |
        _cellHalf;
    final cb = ((cell & (_cubeSide - 1)) << (8 - _cubeBits)) | _cellHalf;

    var bestIndex = 0;
    var bestDistance = 0x7FFFFFFF;
    var secondIndex = 0;
    var secondDistance = 0x7FFFFFFF;

    for (var i = 0; i < _count; i++) {
      final d = _distance(
        r1: cr,
        g1: cg,
        b1: cb,
        r2: _r[i],
        g2: _g[i],
        b2: _b[i],
      );
      if (d < bestDistance) {
        secondDistance = bestDistance;
        secondIndex = bestIndex;
        bestDistance = d;
        bestIndex = i;
      } else if (d < secondDistance) {
        secondDistance = d;
        secondIndex = i;
      }
    }

    // A single-colour palette has no second candidate. Pointing it at the best
    // makes every caller's degenerate case the same one, rather than leaving a
    // sentinel for each of them to remember.
    if (_count == 1) secondIndex = bestIndex;

    _best[cell] = bestIndex;
    _second[cell] = secondIndex;
    _flags[cell] |= _flagFilled;
  }

  /// The exact nearest entry, by brute force. **Not used by the encoder** — it
  /// is what the cube is measured against, and it lets a caller trade speed for
  /// the last fraction of accuracy.
  int exactNearest({required int r, required int g, required int b}) {
    var bestIndex = 0;
    var bestDistance = 0x7FFFFFFF;
    for (var i = 0; i < _count; i++) {
      final d = _distance(
        r1: r,
        g1: g,
        b1: b,
        r2: _r[i],
        g2: _g[i],
        b2: _b[i],
      );
      if (d < bestDistance) {
        bestDistance = d;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  /// The palette entry at [index], packed `0xRRGGBB`.
  ///
  /// Error diffusion must measure its error against **this** — the colour that
  /// will actually be written — and never against the cube's cell centre, or
  /// the 5-bit approximation compounds across the frame.
  int colorAt(int index) => (_r[index] << 16) | (_g[index] << 8) | _b[index];

  int redAt(int index) => _r[index];
  int greenAt(int index) => _g[index];
  int blueAt(int index) => _b[index];
}
