import 'dart:math';

import 'package:gif_writer/gif_writer.dart';
import 'package:gif_writer/src/color_mapper.dart';
import 'package:test/test.dart';

/// The same weighting `ColorMapper` uses, written out independently here.
///
/// Deliberately a second implementation rather than a call into the class under
/// test: a guard that computes its expectation with the code it is checking
/// passes whether or not that code is right.
int weighted({
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

/// Brute-force nearest, for the cube to be measured against.
(int best, int second) scan({
  required List<int> palette,
  required int r,
  required int g,
  required int b,
}) {
  var bestIndex = 0;
  var bestDistance = 1 << 30;
  var secondIndex = 0;
  var secondDistance = 1 << 30;
  for (var i = 0; i < palette.length; i++) {
    final d = weighted(
      r1: r,
      g1: g,
      b1: b,
      r2: (palette[i] >> 16) & 0xFF,
      g2: (palette[i] >> 8) & 0xFF,
      b2: palette[i] & 0xFF,
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
  if (palette.length == 1) secondIndex = bestIndex;
  return (bestIndex, secondIndex);
}

List<int> randomPalette(Random random, int count) => <int>[
  for (var i = 0; i < count; i++) random.nextInt(0x1000000),
];

void main() {
  group('the exact table', () {
    test('finds a colour the palette actually holds', () {
      final palette = <int>[0x000000, 0xFF5500, 0x123456, 0xFFFFFF];
      final mapper = ColorMapper(GifColorTable.packed(palette));
      for (var i = 0; i < palette.length; i++) {
        expect(mapper.exactIndexOf(palette[i]), i);
      }
    });

    test('reports a miss as -1', () {
      final mapper = ColorMapper(GifColorTable.packed(<int>[0x000000, 0xFFFFFF]));
      expect(mapper.exactIndexOf(0x808080), -1);
    });

    test('survives a full 256-colour palette without losing an entry', () {
      // The load factor is 0.25 at 256 entries. If the probe were wrong, some
      // entry would be unreachable — and it would be unreachable silently.
      final random = Random(4);
      final seen = <int>{};
      while (seen.length < 256) {
        seen.add(random.nextInt(0x1000000));
      }
      final palette = seen.toList();
      final mapper = ColorMapper(GifColorTable.packed(palette));
      for (var i = 0; i < palette.length; i++) {
        expect(mapper.exactIndexOf(palette[i]), i, reason: 'entry $i lost');
      }
    });

    test('keeps the first index when the palette repeats a colour', () {
      final mapper = ColorMapper(
        GifColorTable.packed(<int>[0x111111, 0x222222, 0x111111]),
      );
      expect(mapper.exactIndexOf(0x111111), 0);
    });
  });

  group('the cube', () {
    // **The cube is keyed on a cell, so it is exact for that cell's centre and
    // only approximate elsewhere.** Asserting it matches a brute-force scan of
    // an arbitrary query colour would fail against a correct implementation —
    // that is the cache's whole trade. So the fill is checked at the centres,
    // where it is required to be exact.
    test('stores the true nearest pair for every cell centre', () {
      final random = Random(11);
      // Every one of the 32,768 cells for the small palettes; a fixed random
      // sample for 256, where exhaustive checking is 8.4M distance evaluations
      // and would be slow under Chrome for no extra signal.
      for (final (count, step) in <(int, int)>[(2, 8), (17, 8), (256, 32)]) {
        final palette = randomPalette(random, count);
        final mapper = ColorMapper(GifColorTable.packed(palette));
        for (var r = 0; r < 256; r += step) {
          for (var g = 0; g < 256; g += step) {
            for (var b = 0; b < 256; b += step) {
              // The centre of the cell this colour falls in.
              final cr = r | 4;
              final cg = g | 4;
              final cb = b | 4;
              // An exact palette hit legitimately collapses both candidates, so
              // it is excluded rather than weakening the assertion.
              if (mapper.exactIndexOf((cr << 16) | (cg << 8) | cb) >= 0) {
                continue;
              }
              final packed = mapper.candidates(r: cr, g: cg, b: cb);
              final want = scan(palette: palette, r: cr, g: cg, b: cb);
              expect(
                packed & 0xFF,
                want.$1,
                reason: 'best wrong at ($cr,$cg,$cb) for $count colours',
              );
              expect(
                (packed >> 8) & 0xFF,
                want.$2,
                reason: 'second wrong at ($cr,$cg,$cb) for $count colours',
              );
            }
          }
        }
      }
    });

    test('an exact palette colour beats whatever the cell would suggest', () {
      // Two entries inside one 5-bit cell — closer than 8 per channel. The cube
      // alone cannot separate them, and one would be unreachable.
      final palette = <int>[0x000000, 0x404040, 0x424242, 0xFFFFFF];
      final mapper = ColorMapper(GifColorTable.packed(palette));
      expect(mapper.nearest(r: 0x40, g: 0x40, b: 0x40), 1);
      expect(mapper.nearest(r: 0x42, g: 0x42, b: 0x42), 2);
    });

    test('collapses both candidates for an exact match', () {
      final mapper = ColorMapper(
        GifColorTable.packed(<int>[0x000000, 0x808080, 0xFFFFFF]),
      );
      final packed = mapper.candidates(r: 0x80, g: 0x80, b: 0x80);
      expect(packed & 0xFF, 1);
      expect((packed >> 8) & 0xFF, 1, reason: 'no choice to make');
    });
  });

  group('degenerate palettes', () {
    test('a single colour maps everything to it, with no second candidate', () {
      final mapper = ColorMapper(GifColorTable.packed(<int>[0x336699]));
      for (final c in <List<int>>[
        [0, 0, 0],
        [255, 255, 255],
        [0x33, 0x66, 0x99],
      ]) {
        final packed = mapper.candidates(r: c[0], g: c[1], b: c[2]);
        expect(packed & 0xFF, 0);
        expect((packed >> 8) & 0xFF, 0);
      }
    });

    test('duplicate entries do not break the pair', () {
      final mapper = ColorMapper(
        GifColorTable.packed(<int>[0x101010, 0x101010, 0xF0F0F0]),
      );
      final packed = mapper.candidates(r: 0x20, g: 0x20, b: 0x20);
      expect(packed & 0xFF, lessThan(3));
      expect((packed >> 8) & 0xFF, lessThan(3));
    });
  });

  group('exactNearest', () {
    test('agrees with an independent scan on random colours', () {
      final random = Random(23);
      final palette = randomPalette(random, 64);
      final mapper = ColorMapper(GifColorTable.packed(palette));
      for (var i = 0; i < 3000; i++) {
        final r = random.nextInt(256);
        final g = random.nextInt(256);
        final b = random.nextInt(256);
        expect(
          mapper.exactNearest(r: r, g: g, b: b),
          scan(palette: palette, r: r, g: g, b: b).$1,
        );
      }
    });

    test('weights green above blue, which plain Euclidean would not', () {
      // Both entries are exactly 10 away from black in raw RGB, so plain
      // Euclidean sees a tie and the first one wins. Weighted, the green error
      // costs 4x and the blue 3x, so the blue entry must win instead. This
      // fails the moment the weighting is dropped.
      final mapper = ColorMapper(
        GifColorTable.packed(<int>[0x000A00, 0x00000A]),
      );
      expect(mapper.exactNearest(r: 0, g: 0, b: 0), 1);
    });
  });

  test('colorAt returns what will actually be written', () {
    final mapper = ColorMapper(
      GifColorTable.packed(<int>[0x000000, 0x123456, 0xFFFFFF]),
    );
    expect(mapper.colorAt(1), 0x123456);
    expect(mapper.redAt(1), 0x12);
    expect(mapper.greenAt(1), 0x34);
    expect(mapper.blueAt(1), 0x56);
  });
}

