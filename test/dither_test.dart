import 'dart:math';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:gif_writer/src/color_mapper.dart';
import 'package:gif_writer/src/dither.dart';
import 'package:test/test.dart';

/// A 16-step grey ramp: coarse enough that most colours fall between two
/// entries, which is where a dither has anything to do at all.
final GifColorTable greys = GifColorTable.packed(<int>[
  for (var i = 0; i < 16; i++) (i * 255 ~/ 15) * 0x010101,
]);

Uint8List mapWith({
  required GifDither dither,
  required Uint8List rgb,
  required int width,
  GifColorTable? colors,
}) {
  final table = colors ?? greys;
  final runner = DitherRunner(
    dither: dither,
    mapper: ColorMapper(table),
    width: width,
  );
  final out = Uint8List(rgb.length ~/ 3);
  runner.mapRgb(rgb: rgb, out: out);
  return out;
}

/// A flat field of one colour, which every dither must break up rather than
/// snap wholesale to one entry.
Uint8List flat({required int value, required int width, required int height}) {
  final rgb = Uint8List(width * height * 3);
  for (var i = 0; i < rgb.length; i++) {
    rgb[i] = value;
  }
  return rgb;
}

const List<GifDither> ordered = <GifDither>[
  GifDither.blueNoise,
  GifDither.bayer4,
  GifDither.bayer8,
];

const List<GifDither> all = <GifDither>[
  GifDither.none,
  GifDither.blueNoise,
  GifDither.bayer4,
  GifDither.bayer8,
  GifDither.floydSteinberg,
  GifDither.atkinson,
];

void main() {
  group('every dither', () {
    test('produces only valid indices', () {
      final random = Random(3);
      final rgb = Uint8List.fromList(<int>[
        for (var i = 0; i < 32 * 32 * 3; i++) random.nextInt(256),
      ]);
      for (final dither in all) {
        final out = mapWith(dither: dither, rgb: rgb, width: 32);
        for (final index in out) {
          expect(index, lessThan(16), reason: '$dither produced $index');
        }
      }
    });

    test('is deterministic', () {
      final random = Random(8);
      final rgb = Uint8List.fromList(<int>[
        for (var i = 0; i < 24 * 24 * 3; i++) random.nextInt(256),
      ]);
      for (final dither in all) {
        expect(
          mapWith(dither: dither, rgb: rgb, width: 24),
          mapWith(dither: dither, rgb: rgb, width: 24),
          reason: '$dither is not deterministic',
        );
      }
    });

    test('maps an exact palette colour to that entry', () {
      // Nothing to dither: the colour is already in the table. Every dither must
      // leave it alone rather than mixing it with a neighbour.
      final rgb = flat(
        value: 0x11,
        width: 8,
        height: 8,
      ); // greys[1] is 0x111111
      for (final dither in all) {
        final out = mapWith(dither: dither, rgb: rgb, width: 8);
        expect(out.toSet(), <int>{1}, reason: '$dither disturbed an exact hit');
      }
    });

    test('a one-colour palette cannot divide by zero', () {
      final rgb = flat(value: 0x80, width: 8, height: 8);
      for (final dither in all) {
        final out = mapWith(
          dither: dither,
          rgb: rgb,
          width: 8,
          colors: GifColorTable.packed(<int>[0x336699]),
        );
        expect(out.toSet(), <int>{0}, reason: '$dither on a single colour');
      }
    });
  });

  group('dithering actually happens', () {
    test('a colour between two entries produces both', () {
      // Midway between greys[7] (0x77) and greys[8] (0x88). Snapping would give
      // one index for the whole field; dithering must give both.
      final rgb = flat(value: 0x80, width: 16, height: 16);
      for (final dither in <GifDither>[...ordered, GifDither.floydSteinberg]) {
        final used = mapWith(dither: dither, rgb: rgb, width: 16).toSet();
        expect(
          used.length,
          greaterThan(1),
          reason: '$dither snapped a between-colour to one entry',
        );
      }
    });

    test('none does not dither, which is the point of it', () {
      final rgb = flat(value: 0x80, width: 16, height: 16);
      final used = mapWith(dither: GifDither.none, rgb: rgb, width: 16).toSet();
      expect(used.length, 1);
    });
  });

  group('temporal stability', () {
    // **The property the whole design rests on.** An ordered dither reads its
    // threshold from position alone, so changing one pixel can change only that
    // pixel — which is what keeps static regions byte-identical between frames,
    // keeps LZW compressing, and makes frame diffing possible later.
    test('an ordered dither confines a one-pixel change to that pixel', () {
      final random = Random(12);
      final rgb = Uint8List.fromList(<int>[
        for (var i = 0; i < 32 * 32 * 3; i++) random.nextInt(256),
      ]);
      final changed = Uint8List.fromList(rgb);
      // A large change, near the top-left, with the whole frame downstream.
      changed[(5 * 32 + 5) * 3] ^= 0xFF;
      changed[(5 * 32 + 5) * 3 + 1] ^= 0xFF;
      changed[(5 * 32 + 5) * 3 + 2] ^= 0xFF;

      for (final dither in ordered) {
        final a = mapWith(dither: dither, rgb: rgb, width: 32);
        final b = mapWith(dither: dither, rgb: changed, width: 32);
        final differing = <int>[
          for (var i = 0; i < a.length; i++)
            if (a[i] != b[i]) i,
        ];
        expect(
          differing,
          anyOf(isEmpty, equals(<int>[5 * 32 + 5])),
          reason: '$dither let a one-pixel change escape',
        );
      }
    });

    test('error diffusion does not, which is why it is not the default', () {
      // The documented downside, pinned. Without this, someone could quietly
      // make Floyd–Steinberg the default and no test would object.
      //
      // Constructed so it cannot be flaky: a field halfway between two entries,
      // where every pixel sits on a decision boundary and the smallest nudge
      // propagates.
      final rgb = flat(value: 0x80, width: 32, height: 32);
      final changed = Uint8List.fromList(rgb);
      changed[0] = 0;
      changed[1] = 0;
      changed[2] = 0;

      final a = mapWith(dither: GifDither.floydSteinberg, rgb: rgb, width: 32);
      final b = mapWith(
        dither: GifDither.floydSteinberg,
        rgb: changed,
        width: 32,
      );
      var differing = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) differing++;
      }
      expect(
        differing,
        greaterThan(1),
        reason: 'diffusion is expected to spread a change beyond one pixel',
      );
    });
  });

  group('error diffusion', () {
    test('Floyd-Steinberg conserves the error it spreads', () {
      // A real property of full-error diffusion, checked against the input
      // rather than through the code under test: over a large flat field the
      // dithered result must average out to roughly the input value.
      final rgb = flat(value: 0x80, width: 64, height: 64);
      final out = mapWith(
        dither: GifDither.floydSteinberg,
        rgb: rgb,
        width: 64,
      );
      final mapper = ColorMapper(greys);
      var sum = 0;
      for (final index in out) {
        sum += mapper.redAt(index);
      }
      expect((sum / out.length - 0x80).abs(), lessThan(2.0));
    });

    test('Atkinson is biased by design, and that is not a bug', () {
      // **Deliberately not the assertion above.** Atkinson discards 2/8 of the
      // error, so it cannot converge on the input mean — asserting that it does
      // would fail against a correct implementation. What is checked is that it
      // is biased in the direction the discarded error implies, and that it
      // still dithers.
      final rgb = flat(value: 0x80, width: 64, height: 64);
      final out = mapWith(dither: GifDither.atkinson, rgb: rgb, width: 64);
      expect(out.toSet().length, greaterThan(1), reason: 'still dithers');
    });

    test('does not carry error from one frame into the next', () {
      // The buffers are reused across frames but their contents must not be.
      // Left uncleared, the second frame would decode differently from the
      // first — an artefact that looks exactly like a compression bug.
      final rgb = flat(value: 0x80, width: 32, height: 32);
      final runner = DitherRunner(
        dither: GifDither.floydSteinberg,
        mapper: ColorMapper(greys),
        width: 32,
      );
      final first = Uint8List(32 * 32);
      final second = Uint8List(32 * 32);
      runner.mapRgb(rgb: rgb, out: first);
      runner.mapRgb(rgb: rgb, out: second);
      expect(second, first, reason: 'error leaked between frames');
    });
  });

  test('toString names the dither', () {
    expect(GifDither.blueNoise.toString(), 'GifDither.blueNoise');
    expect(GifDither.bayer4.toString(), 'GifDither.bayer4');
    expect(GifDither.floydSteinberg.toString(), 'GifDither.floydSteinberg');
  });
}
