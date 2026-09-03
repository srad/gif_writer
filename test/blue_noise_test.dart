import 'dart:math';

import 'package:gif_writer/src/blue_noise.g.dart';
import 'package:test/test.dart';

/// Energy in the lowest frequencies, as a fraction of the whole spectrum.
///
/// **This is what makes noise "blue".** Blue noise puts its energy at high
/// spatial frequencies, where the eye is least sensitive; white noise spreads it
/// evenly. Checking the property directly is the only way to know the committed
/// table is what the generator claims — a comment saying so proves nothing, and
/// re-running the generator inside the test would only prove the generator
/// agrees with itself.
///
/// Only the lowest bins are evaluated. A full 64x64 DFT is 16.7M operations and
/// would be slow under Chrome for no extra signal.
double lowFrequencyFraction(List<int> ranks, {required int side}) {
  final n = ranks.length;
  var low = 0.0;
  var total = 0.0;

  // The mean is subtracted so the DC term is zero and cannot swamp the result.
  final values = <double>[for (final r in ranks) r / n - 0.5];

  for (var v = -8; v <= 8; v++) {
    for (var u = -8; u <= 8; u++) {
      if (u == 0 && v == 0) continue;
      var re = 0.0;
      var im = 0.0;
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final angle = -2 * pi * (u * x + v * y) / side;
          final value = values[y * side + x];
          re += value * cos(angle);
          im += value * sin(angle);
        }
      }
      final power = re * re + im * im;
      total += power;
      if (u.abs() <= 4 && v.abs() <= 4) low += power;
    }
  }
  return low / total;
}

void main() {
  test('the table is 64x64', () {
    expect(blueNoiseSide, 64);
    expect(blueNoiseRanks.length, blueNoiseSide * blueNoiseSide);
  });

  test('the ranks are a permutation of 0..4095', () {
    // Every rank exactly once. If one repeated, two positions would share a
    // threshold and the dither would be biased there — invisibly.
    final seen = List<bool>.filled(blueNoiseRanks.length, false);
    for (final rank in blueNoiseRanks) {
      expect(rank, inInclusiveRange(0, blueNoiseRanks.length - 1));
      expect(seen[rank], isFalse, reason: 'rank $rank appears twice');
      seen[rank] = true;
    }
    expect(seen.every((s) => s), isTrue, reason: 'a rank is missing');
  });

  test('its energy is at high frequencies, unlike a random permutation', () {
    // **A relative baseline, not an invented threshold.** "Below 0.01" would be
    // an arbitrary number that a white-noise table might also pass; being far
    // below a shuffle of the very same values is the actual claim.
    final blue = lowFrequencyFraction(
      blueNoiseRanks.toList(),
      side: blueNoiseSide,
    );

    final shuffled = blueNoiseRanks.toList()..shuffle(Random(99));
    final white = lowFrequencyFraction(shuffled, side: blueNoiseSide);

    expect(
      blue,
      lessThan(white / 10),
      reason: 'low-frequency energy $blue is not far below white noise $white; '
          'the committed table is not blue noise',
    );
  });

  test('no value clusters with its neighbours', () {
    // A cheap structural cross-check: for a blue-noise matrix, positions holding
    // nearby ranks should be spread apart. This catches a **structured**
    // replacement — a Bayer matrix, or a gradient — where the DFT check above is
    // what catches an unstructured one. Verified by tampering: a shuffled table
    // passes this and fails the DFT check, so the two are not redundant.
    const bucket = 256;
    var adjacent = 0;
    for (var y = 0; y < blueNoiseSide; y++) {
      for (var x = 0; x < blueNoiseSide; x++) {
        final here = blueNoiseRanks[y * blueNoiseSide + x] ~/ bucket;
        final right =
            blueNoiseRanks[y * blueNoiseSide + ((x + 1) & (blueNoiseSide - 1))] ~/
                bucket;
        if (here == right) adjacent++;
      }
    }
    // With 16 buckets, chance alone puts about 1/16 of neighbours in the same
    // bucket. Clustering would push this well above that.
    expect(adjacent, lessThan(blueNoiseRanks.length ~/ 8));
  });
}
