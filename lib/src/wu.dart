import 'dart:typed_data';

/// Wu's greedy orthogonal bipartitioning (Xiaolin Wu, *Graphics Gems II*, 1991).
///
/// Derives a palette of at most [maxColors] entries from [rgb] — three bytes per
/// pixel — and returns it as packed RGB bytes, ready for `GifColorTable.rgb`.
///
/// **Why offer Wu.** It is the highest-fidelity of the fast, non-iterative
/// quantisers in Celebi's 2023 survey: rather than averaging by population like
/// an octree, it repeatedly splits the colour box of greatest weighted variance
/// along the axis that leaves the least variance behind, so the palette follows
/// the image's real structure. The cost is a fixed **~1.4 MB** moment histogram
/// (five `Float64List`s over a 33³ grid) — but it is built once, for one global
/// palette, and freed before a single frame streams, so it never touches the
/// held-memory figure this package advertises. `octree.dart` is the default when
/// that transient does not pay for itself.
///
/// **Output is full 8-bit.** The 33³ grid bins colours to five bits, but every
/// palette entry is a *weighted centroid* of real pixel values, not a bin
/// centre — so the returned colours span the whole 0–255 range.
///
/// **Web-safe.** The squared moments reach about 1e12 for a large frame, past a
/// 32-bit range, so all moment tables are `Float64List`; a `double` holds these
/// exactly and behaves the same on the VM and the web.
Uint8List wuQuantize(Uint8List rgb, {required int maxColors}) {
  assert(maxColors >= 1, 'a palette needs at least one colour');
  assert(rgb.length % 3 == 0, 'rgb must be three bytes per pixel');
  return _WuQuantizer(rgb).run(maxColors);
}

/// 32 bins per channel plus a guard plane at index 0 for the cumulative sums.
const int _side = 33;
const int _cells = _side * _side * _side;

/// Which axis a box is being cut along.
enum _Axis { red, green, blue }

class _WuQuantizer {
  _WuQuantizer(this._rgb)
    : _wt = Float64List(_cells),
      _mr = Float64List(_cells),
      _mg = Float64List(_cells),
      _mb = Float64List(_cells),
      _m2 = Float64List(_cells);

  final Uint8List _rgb;

  /// The moments: pixel count, the three channel sums, and the sum of squared
  /// magnitudes. Built as a plain histogram, then turned into cumulative sums so
  /// any box's totals are eight array reads.
  final Float64List _wt;
  final Float64List _mr;
  final Float64List _mg;
  final Float64List _mb;
  final Float64List _m2;

  static int _index(int r, int g, int b) => (r * _side + g) * _side + b;

  Uint8List run(int maxColors) {
    _histogram();
    _cumulate();

    final boxes = List<_Box>.generate(maxColors, (_) => _Box());
    boxes[0].r1 = 32;
    boxes[0].g1 = 32;
    boxes[0].b1 = 32;

    final variance = Float64List(maxColors);
    var next = 0;
    var count = maxColors;

    for (var i = 1; i < maxColors; i++) {
      if (_cut(boxes[next], boxes[i])) {
        variance[next] = boxes[next].volume > 1 ? _variance(boxes[next]) : 0.0;
        variance[i] = boxes[i].volume > 1 ? _variance(boxes[i]) : 0.0;
      } else {
        // The chosen box could not be split further; it is final. Retry this
        // slot against the next-best box.
        variance[next] = 0.0;
        i--;
      }

      next = 0;
      var largest = variance[0];
      for (var k = 1; k <= i; k++) {
        if (variance[k] > largest) {
          largest = variance[k];
          next = k;
        }
      }
      if (largest <= 0.0) {
        // Nothing left with any variance to split: the image has fewer distinct
        // colours than the cap.
        count = i + 1;
        break;
      }
    }

    return _palette(boxes, count);
  }

  void _histogram() {
    for (var p = 0; p < _rgb.length; p += 3) {
      final r = _rgb[p];
      final g = _rgb[p + 1];
      final b = _rgb[p + 2];
      // Five-bit bin, offset by one to leave row/column/plane 0 as the guard the
      // cumulative step reads below its first real cell.
      final ind = _index((r >> 3) + 1, (g >> 3) + 1, (b >> 3) + 1);
      _wt[ind] += 1;
      _mr[ind] += r;
      _mg[ind] += g;
      _mb[ind] += b;
      _m2[ind] += r * r + g * g + b * b;
    }
  }

  /// Turns the histogram into 3-D cumulative sums, so [_volume] can read any
  /// box's total from its eight corners.
  void _cumulate() {
    final area = Float64List(_side);
    final areaR = Float64List(_side);
    final areaG = Float64List(_side);
    final areaB = Float64List(_side);
    final area2 = Float64List(_side);

    for (var r = 1; r < _side; r++) {
      area.fillRange(0, _side, 0);
      areaR.fillRange(0, _side, 0);
      areaG.fillRange(0, _side, 0);
      areaB.fillRange(0, _side, 0);
      area2.fillRange(0, _side, 0);
      for (var g = 1; g < _side; g++) {
        var line = 0.0;
        var lineR = 0.0;
        var lineG = 0.0;
        var lineB = 0.0;
        var line2 = 0.0;
        for (var b = 1; b < _side; b++) {
          final ind = _index(r, g, b);
          line += _wt[ind];
          lineR += _mr[ind];
          lineG += _mg[ind];
          lineB += _mb[ind];
          line2 += _m2[ind];

          area[b] += line;
          areaR[b] += lineR;
          areaG[b] += lineG;
          areaB[b] += lineB;
          area2[b] += line2;

          final prev = _index(r - 1, g, b);
          _wt[ind] = _wt[prev] + area[b];
          _mr[ind] = _mr[prev] + areaR[b];
          _mg[ind] = _mg[prev] + areaG[b];
          _mb[ind] = _mb[prev] + areaB[b];
          _m2[ind] = _m2[prev] + area2[b];
        }
      }
    }
  }

  /// A box's total for one moment table, by inclusion–exclusion over its eight
  /// corners of the cumulative sums.
  static double _volume(_Box c, Float64List m) =>
      m[_index(c.r1, c.g1, c.b1)] -
      m[_index(c.r1, c.g1, c.b0)] -
      m[_index(c.r1, c.g0, c.b1)] +
      m[_index(c.r1, c.g0, c.b0)] -
      m[_index(c.r0, c.g1, c.b1)] +
      m[_index(c.r0, c.g1, c.b0)] +
      m[_index(c.r0, c.g0, c.b1)] -
      m[_index(c.r0, c.g0, c.b0)];

  /// The part of [_volume] that does not depend on the cut position, over one
  /// face of the box.
  static double _bottom(_Box c, _Axis dir, Float64List m) {
    switch (dir) {
      case _Axis.red:
        return -m[_index(c.r0, c.g1, c.b1)] +
            m[_index(c.r0, c.g1, c.b0)] +
            m[_index(c.r0, c.g0, c.b1)] -
            m[_index(c.r0, c.g0, c.b0)];
      case _Axis.green:
        return -m[_index(c.r1, c.g0, c.b1)] +
            m[_index(c.r1, c.g0, c.b0)] +
            m[_index(c.r0, c.g0, c.b1)] -
            m[_index(c.r0, c.g0, c.b0)];
      case _Axis.blue:
        return -m[_index(c.r1, c.g1, c.b0)] +
            m[_index(c.r1, c.g0, c.b0)] +
            m[_index(c.r0, c.g1, c.b0)] -
            m[_index(c.r0, c.g0, c.b0)];
    }
  }

  /// The rest of [_volume] up to position [pos] along [dir].
  static double _top(_Box c, _Axis dir, int pos, Float64List m) {
    switch (dir) {
      case _Axis.red:
        return m[_index(pos, c.g1, c.b1)] -
            m[_index(pos, c.g1, c.b0)] -
            m[_index(pos, c.g0, c.b1)] +
            m[_index(pos, c.g0, c.b0)];
      case _Axis.green:
        return m[_index(c.r1, pos, c.b1)] -
            m[_index(c.r1, pos, c.b0)] -
            m[_index(c.r0, pos, c.b1)] +
            m[_index(c.r0, pos, c.b0)];
      case _Axis.blue:
        return m[_index(c.r1, c.g1, pos)] -
            m[_index(c.r1, c.g0, pos)] -
            m[_index(c.r0, c.g1, pos)] +
            m[_index(c.r0, c.g0, pos)];
    }
  }

  /// The weighted variance of a box: the quantity a split reduces.
  double _variance(_Box c) {
    final dr = _volume(c, _mr);
    final dg = _volume(c, _mg);
    final db = _volume(c, _mb);
    final w = _volume(c, _wt);
    final xx = _volume(c, _m2);
    return xx - (dr * dr + dg * dg + db * db) / w;
  }

  /// Finds the position along [dir] that best splits the box, returning the sum
  /// of the two halves' explained sums (larger is better) and the cut in [_Cut].
  double _maximize(
    _Box c,
    _Axis dir,
    int first,
    int last,
    _CutResult result,
    double wholeR,
    double wholeG,
    double wholeB,
    double wholeW,
  ) {
    final baseR = _bottom(c, dir, _mr);
    final baseG = _bottom(c, dir, _mg);
    final baseB = _bottom(c, dir, _mb);
    final baseW = _bottom(c, dir, _wt);

    var max = 0.0;
    result.position = -1;
    for (var i = first; i < last; i++) {
      var halfR = baseR + _top(c, dir, i, _mr);
      var halfG = baseG + _top(c, dir, i, _mg);
      var halfB = baseB + _top(c, dir, i, _mb);
      var halfW = baseW + _top(c, dir, i, _wt);

      // An empty half cannot be a box; skip rather than divide by zero.
      if (halfW == 0) continue;
      var temp = (halfR * halfR + halfG * halfG + halfB * halfB) / halfW;

      halfR = wholeR - halfR;
      halfG = wholeG - halfG;
      halfB = wholeB - halfB;
      halfW = wholeW - halfW;
      if (halfW == 0) continue;
      temp += (halfR * halfR + halfG * halfG + halfB * halfB) / halfW;

      if (temp > max) {
        max = temp;
        result.position = i;
      }
    }
    return max;
  }

  /// Splits [set1] in two, moving the far half into [set2]. Returns false when no
  /// axis can be cut — the box is a single colour and is final.
  bool _cut(_Box set1, _Box set2) {
    final wholeR = _volume(set1, _mr);
    final wholeG = _volume(set1, _mg);
    final wholeB = _volume(set1, _mb);
    final wholeW = _volume(set1, _wt);

    final cutR = _CutResult();
    final cutG = _CutResult();
    final cutB = _CutResult();
    final maxR = _maximize(
      set1,
      _Axis.red,
      set1.r0 + 1,
      set1.r1,
      cutR,
      wholeR,
      wholeG,
      wholeB,
      wholeW,
    );
    final maxG = _maximize(
      set1,
      _Axis.green,
      set1.g0 + 1,
      set1.g1,
      cutG,
      wholeR,
      wholeG,
      wholeB,
      wholeW,
    );
    final maxB = _maximize(
      set1,
      _Axis.blue,
      set1.b0 + 1,
      set1.b1,
      cutB,
      wholeR,
      wholeG,
      wholeB,
      wholeW,
    );

    final _Axis dir;
    if (maxR >= maxG && maxR >= maxB) {
      dir = _Axis.red;
      if (cutR.position < 0) return false;
    } else if (maxG >= maxR && maxG >= maxB) {
      dir = _Axis.green;
    } else {
      dir = _Axis.blue;
    }

    set2.r1 = set1.r1;
    set2.g1 = set1.g1;
    set2.b1 = set1.b1;

    switch (dir) {
      case _Axis.red:
        set2.r0 = set1.r1 = cutR.position;
        set2.g0 = set1.g0;
        set2.b0 = set1.b0;
      case _Axis.green:
        set2.g0 = set1.g1 = cutG.position;
        set2.r0 = set1.r0;
        set2.b0 = set1.b0;
      case _Axis.blue:
        set2.b0 = set1.b1 = cutB.position;
        set2.r0 = set1.r0;
        set2.g0 = set1.g0;
    }

    set1.volume =
        (set1.r1 - set1.r0) * (set1.g1 - set1.g0) * (set1.b1 - set1.b0);
    set2.volume =
        (set2.r1 - set2.r0) * (set2.g1 - set2.g0) * (set2.b1 - set2.b0);
    return true;
  }

  Uint8List _palette(List<_Box> boxes, int count) {
    // Copying builder: the 3-byte scratch is reused per entry, so the builder
    // must copy each rather than hold a reference to it.
    final out = BytesBuilder();
    final entry = Uint8List(3);
    for (var k = 0; k < count; k++) {
      final w = _volume(boxes[k], _wt);
      if (w <= 0) continue; // an empty box contributes no colour
      final half = w / 2;
      entry[0] = ((_volume(boxes[k], _mr) + half) ~/ w).clamp(0, 255);
      entry[1] = ((_volume(boxes[k], _mg) + half) ~/ w).clamp(0, 255);
      entry[2] = ((_volume(boxes[k], _mb) + half) ~/ w).clamp(0, 255);
      out.add(entry);
    }
    // Every image has at least one colour; if rounding left nothing (only with a
    // degenerate all-empty input, which the caller's validation forbids), fall
    // back to one black entry rather than an empty table.
    if (out.isEmpty) return Uint8List(3);
    return out.toBytes();
  }
}

/// A box in the 5-bit colour cube, held as the half-open corners `(r0,r1]` etc.
class _Box {
  int r0 = 0;
  int r1 = 0;
  int g0 = 0;
  int g1 = 0;
  int b0 = 0;
  int b1 = 0;
  int volume = 0;
}

/// The chosen cut position out of [_WuQuantizer._maximize].
class _CutResult {
  int position = -1;
}
