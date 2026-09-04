"""Generates the blue-noise threshold matrix by void-and-cluster.

    python tool/blue_noise.py > lib/src/blue_noise.g.dart

Ulichney, "The void-and-cluster method for dither array generation" (1993).

**Why a generated table rather than Bayer.** An ordered dither needs a threshold
per position. Bayer's recursive matrix is free but its structure is a regular
grid, and the eye finds regular grids at low palette counts far more objectionable
than the same amount of unstructured noise. Blue noise has the same properties
that matter here — it is a fixed table, so the dither stays stateless, position-
only, and therefore temporally stable and periodic enough for LZW — but its energy
sits at high spatial frequencies, where vision is least sensitive.

The algorithm, in one paragraph: start from a sparse random binary pattern; repeatedly
move the point in the tightest *cluster* to the largest *void*, until moving stops
changing anything; then rank every position by repeatedly removing the tightest
cluster and inserting into the largest void, which orders all N positions. Cluster
and void are found by convolving the binary pattern with a Gaussian, wrapped
toroidally so the result tiles seamlessly — which it must, since it is indexed by
`x & 63`.
"""

import numpy as np

SIDE = 64
SIGMA = 1.9          # Ulichney's recommendation; controls the noise's spectrum
INITIAL_FRACTION = 0.1


def gaussian_kernel(side, sigma):
    """A toroidally-wrapped Gaussian, as a frequency-domain filter.

    Convolution is done by FFT because the pattern is filtered thousands of
    times; doing it directly would be minutes rather than seconds.
    """
    axis = np.arange(side)
    axis = np.minimum(axis, side - axis)      # wrap: distance on a torus
    dy, dx = np.meshgrid(axis, axis, indexing="ij")
    kernel = np.exp(-(dx**2 + dy**2) / (2.0 * sigma**2))
    return np.fft.rfft2(kernel)


def filtered(pattern, kernel_f):
    return np.fft.irfft2(np.fft.rfft2(pattern.astype(np.float64)) * kernel_f,
                         s=pattern.shape)


def tightest_cluster(pattern, kernel_f):
    """The 1 whose neighbourhood is most crowded."""
    energy = filtered(pattern, kernel_f)
    energy[pattern == 0] = -np.inf
    return np.unravel_index(np.argmax(energy), pattern.shape)


def largest_void(pattern, kernel_f):
    """The 0 whose neighbourhood is most empty."""
    energy = filtered(pattern, kernel_f)
    energy[pattern == 1] = np.inf
    return np.unravel_index(np.argmin(energy), pattern.shape)


def generate(side=SIDE, sigma=SIGMA, seed=7):
    rng = np.random.default_rng(seed)
    kernel_f = gaussian_kernel(side, sigma)
    total = side * side

    # Phase 0: a random sparse pattern, then relax it until every point sits
    # about as far from its neighbours as it can.
    pattern = np.zeros((side, side), dtype=np.uint8)
    count = int(total * INITIAL_FRACTION)
    flat = rng.choice(total, size=count, replace=False)
    pattern.flat[flat] = 1

    while True:
        cluster = tightest_cluster(pattern, kernel_f)
        pattern[cluster] = 0
        void = largest_void(pattern, kernel_f)
        if void == cluster:
            # Removing and reinserting in the same place: settled.
            pattern[cluster] = 1
            break
        pattern[void] = 1

    prototype = pattern.copy()
    rank = np.full((side, side), -1, dtype=np.int32)

    # Phase 1: rank the initial points, densest cluster first, counting down.
    work = prototype.copy()
    for r in range(count - 1, -1, -1):
        cluster = tightest_cluster(work, kernel_f)
        work[cluster] = 0
        rank[cluster] = r

    # Phase 2: fill the first half, largest void first, counting up.
    work = prototype.copy()
    for r in range(count, (total + 1) // 2):
        void = largest_void(work, kernel_f)
        work[void] = 1
        rank[void] = r

    # Phase 3: past halfway the roles swap — the *complement* is now the sparse
    # pattern, so the largest void of the whole is the tightest cluster of the
    # complement. Getting this backwards is the classic way to end up with a
    # matrix whose top half is blue noise and whose bottom half is not.
    for r in range((total + 1) // 2, total):
        cluster = tightest_cluster(1 - work, kernel_f)
        work[cluster] = 1
        rank[cluster] = r

    assert rank.min() == 0 and rank.max() == total - 1
    assert len(np.unique(rank)) == total, "ranks must be a permutation"
    return rank


def low_frequency_energy(rank):
    """How much of the spectrum sits at low frequencies. Lower is bluer."""
    side = rank.shape[0]
    normalised = rank.astype(np.float64) / rank.size - 0.5
    spectrum = np.abs(np.fft.fft2(normalised)) ** 2
    spectrum[0, 0] = 0.0
    low = 0.0
    for y in range(-4, 5):
        for x in range(-4, 5):
            low += spectrum[y % side, x % side]
    return low / spectrum.sum()


if __name__ == "__main__":
    import sys

    rank = generate()
    white = np.random.default_rng(1).permutation(rank.size).reshape(rank.shape)

    blue_lf = low_frequency_energy(rank)
    white_lf = low_frequency_energy(white)
    print(f"low-frequency energy: blue {blue_lf:.5f}  white {white_lf:.5f}  "
          f"ratio {blue_lf / white_lf:.3f}", file=sys.stderr)
    print(f"permutation of 0..{rank.size - 1}: "
          f"{len(np.unique(rank)) == rank.size}", file=sys.stderr)

    # ASCII only in the emitted Dart. Piping through a Windows console encodes
    # stdout as cp1252, and an em-dash arrives in the committed file as a
    # replacement character.
    values = ", ".join(str(v) for v in rank.flatten())
    print(f"""// GENERATED by tool/blue_noise.py - do not edit by hand.
//
// A {SIDE}x{SIDE} void-and-cluster blue-noise matrix (Ulichney 1993), as ranks
// 0..{rank.size - 1}. The dither turns a rank into a threshold; what matters here is
// that the ranks are a permutation and that their energy sits at high spatial
// frequencies, both of which `test/blue_noise_test.dart` checks against the
// committed table rather than trusting this comment.
//
// Measured at generation: low-frequency energy {blue_lf:.8f}, against
// {white_lf:.8f} for a white-noise permutation of the same values - a ratio of
// {blue_lf / white_lf:.6f}. Printed to eight places on purpose: at five it reads
// as a flat 0.00000, which looks like a bug rather than a result.
library;

import 'dart:typed_data';

/// Side of the square matrix. A power of two, so the dither can index it with a
/// mask rather than a modulo.
const int blueNoiseSide = {SIDE};

/// Ranks 0..{rank.size - 1}, row-major.
///
/// Built once, lazily: a `Uint16List` cannot be `const`, and {rank.size} entries as a
/// const `List<int>` would be both slower to index and larger in the snapshot.
///
/// The formatter is switched off around the literal: left to itself it gives
/// each of the {rank.size} ranks a line of its own, turning a 29-line file into a
/// {rank.size + 26}-line one for no gain to anybody reading it.
// dart format off
final Uint16List blueNoiseRanks = Uint16List.fromList(const <int>[
  {values},
]);
// dart format on
""")
