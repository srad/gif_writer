import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

/// The three value-like public types gained `==`/`hashCode` so a caller can
/// compare them or key a cache on them. These pin the behaviour that matters:
/// equal values are equal *and* hash equal, and the fields that distinguish two
/// values actually do.
void main() {
  group('GifRepeat', () {
    test('equal by play count, and times(1) folds to once', () {
      expect(GifRepeat.forever, equals(GifRepeat.forever));
      expect(GifRepeat.times(3), equals(GifRepeat.times(3)));
      expect(GifRepeat.times(3).hashCode, GifRepeat.times(3).hashCode);
      // times(1) is documented to become `once`; equality must agree.
      expect(GifRepeat.times(1), equals(GifRepeat.once));
    });

    test('distinct counts differ', () {
      expect(GifRepeat.once, isNot(equals(GifRepeat.forever)));
      expect(GifRepeat.times(3), isNot(equals(GifRepeat.times(4))));
    });
  });

  group('GifDither', () {
    final all = <GifDither>[
      GifDither.none,
      GifDither.blueNoise,
      GifDither.bayer4,
      GifDither.bayer8,
      GifDither.floydSteinberg,
      GifDither.atkinson,
    ];

    test('each static instance is self-equal and hash-stable', () {
      for (final d in all) {
        expect(d, equals(d));
        expect(d.hashCode, d.hashCode);
      }
    });

    test('the six are pairwise distinct', () {
      for (var i = 0; i < all.length; i++) {
        for (var j = i + 1; j < all.length; j++) {
          expect(
            all[i],
            isNot(equals(all[j])),
            reason: '${all[i]} vs ${all[j]}',
          );
        }
      }
    });

    test('kind alone separates the null-matrix, zero-side dithers', () {
      // none, floydSteinberg and atkinson share side 0 and a null matrix, so
      // only _kind tells them apart — the reason it is in `==` and `hashCode`.
      expect(GifDither.none, isNot(equals(GifDither.floydSteinberg)));
      expect(GifDither.floydSteinberg, isNot(equals(GifDither.atkinson)));
      expect(GifDither.blueNoise, isNot(equals(GifDither.bayer4)));
    });
  });

  group('GifColorTable', () {
    test('equal when the colours match, whatever built them', () {
      final a = GifColorTable.packed(<int>[0x000000, 0xFF0000, 0x00FF00]);
      final b = GifColorTable.rgb(<int>[0, 0, 0, 255, 0, 0, 0, 255, 0]);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('differ when a channel or the length differs', () {
      final a = GifColorTable.packed(<int>[0x000000, 0xFFFFFF]);
      final b = GifColorTable.packed(<int>[0x000000, 0xFFFFFE]);
      final shorter = GifColorTable.packed(<int>[0x000000]);
      expect(a, isNot(equals(b)));
      expect(a, isNot(equals(shorter)));
    });

    test('is usable as a map key', () {
      final map = <GifColorTable, String>{
        GifColorTable.packed(<int>[0x112233, 0x445566]): 'found',
      };
      expect(map[GifColorTable.packed(<int>[0x112233, 0x445566])], 'found');
    });
  });
}
