# Maintenance review: November 7, 2026

The Dart 3.7.0 minimum, public API, encoder defaults, and zero runtime dependencies
are preserved. Build artifacts are excluded from publication and analysis.
The lint constraint permits 5.1.1 on the minimum SDK and 6.1.0 on current Dart.
The existing image and test constraints already resolve current compatible tools.

## Compatibility and regression checks

Verified on Windows x64 using the SDK executables directly. The minimum-SDK
checks used a separate source copy, dependency resolution, and package cache under
the ignored build directory. All 42 Dart source files matched the final working
tree after Git's line-ending normalization. The working package's lock file and
package configuration were unchanged by those checks.

| Dart SDK | lints | test | image | Analysis, fatal infos | VM tests | Chrome tests |
|---|---|---|---|---|---:|---:|
| 3.7.0 | 5.1.1 | 1.31.0 | 4.12.0 | No issues | 195 | 182 |
| 3.13.7 | 6.1.0 | 1.33.0 | 4.12.0 | No issues | 195 | 182 |

Current-SDK VM line coverage increased from 885/898 (98.6%) to 887/898 (98.8%).
These figures describe the VM-loaded libraries; the browser file-sink stub is
checked separately by the Chrome suite. Remaining uncovered lines include
diagnostic string methods, value-comparison fallbacks, the legacy indices getter,
and the defensive empty-sub-block rewind path. Coverage was collected with:

```console
dart test --branch-coverage --coverage=build/maintenance_review/final-coverage
dart run coverage:format_coverage --lcov --in=build/maintenance_review/final-coverage --out=build/maintenance_review/final.info --report-on=lib
```

The corrected epoch test writes 1,025 small frames: a distinctive pattern, 1,022
zero frames, the original pattern, and a reversed pattern. Each frame starts one
generation. The zero frames preserve the first generation's hash entries until
frame 1023 reuses that generation. Every decoded frame is checked.

An isolated mutation removed only the hash-table clear. The test failed normally
at frame 1023, pixel 0: expected 1, actual 0. It did not reach its external
30-second deadline. The production encoder passes, and coverage confirms execution
of both the table clear and epoch reset. The mutation copy was restored.

The sub-block test now asserts the boundary itself: an 810-pixel seeded
four-colour fixture produces one 255-byte data block. Both minimum and default
staging buffers pass strict EOI parsing and independent pixel decoding, with the
terminator immediately followed by the final trailer.

Delay tests cover rounding, negative values, both delay bytes, saturation, and
clearing a previous maximum delay. A browser-only test checks that valid
`toFile` calls report `UnsupportedError`.

## Packed palette experiment

**Decision: reject the additional cache and retain the original mapper.**
All measured gaps fell within the agreed variation threshold, including both
default blue-noise cases. These trials establish no performance gain.

The sole production variable was an additional `Uint32List` palette cache,
replacing six channel loads with two packed loads in ordered dithering and three
with one in error diffusion. Existing channel arrays and mapping calculations
were preserved. Added storage would have been at most 1 KiB of typed-data payload
plus object overhead; this is a static storage estimate.

Both executables used Dart 3.13.7 AOT, the identical benchmark harness, a 64 KiB
staging buffer, a discarding sink, and awaited frame writes. Each case encoded
30 repetitions of the deterministic 256x256 photographic RGB input, with a
supplied 27- or 216-colour palette. Timing included mapping, encoding, flushing,
and close, beginning after writer construction. Each case first used two
separate one-frame warm-up writers.

Nine paired trials ran serially, alternating AB/BA order, without concurrent test
runs. Reported rates are Mpx/s: median (minimum-maximum).

| Dither | Colours | Baseline | Candidate | Gate result |
|---|---:|---:|---:|---|
| none | 27 | 103.44 (57.21-107.07) | 99.04 (50.22-110.30) | level |
| bayer4 | 27 | 43.94 (33.28-52.43) | 44.53 (26.97-53.02) | level |
| bayer8 | 27 | 46.78 (32.92-51.28) | 42.85 (28.78-53.02) | level |
| blueNoise | 27 | 43.42 (30.15-44.94) | 35.56 (25.65-41.53) | level |
| floydSteinberg | 27 | 22.16 (19.31-28.11) | 22.86 (15.02-26.36) | level |
| atkinson | 27 | 21.59 (14.33-25.06) | 20.77 (13.45-24.19) | level |
| none | 216 | 77.96 (69.05-90.59) | 73.45 (46.11-92.94) | level |
| bayer4 | 216 | 37.74 (31.17-43.87) | 42.35 (29.19-44.85) | level |
| bayer8 | 216 | 36.97 (27.48-45.27) | 41.85 (29.88-44.65) | level |
| blueNoise | 216 | 37.63 (29.24-41.01) | 38.65 (29.96-41.94) | level |
| floydSteinberg | 216 | 21.90 (18.69-24.16) | 24.22 (19.95-26.67) | level |
| atkinson | 216 | 20.72 (15.75-24.11) | 22.72 (19.28-24.31) | level |

The gate compares the median-rate gap with the larger full throughput range.
A gain must exceed that range in both blue-noise cases, with no regression
exceeding the range elsewhere. Otherwise the candidate is discarded.
[Raw samples and computed verdicts](maintenance-review.json) retain all nine
microsecond timings per version and case, output sizes, and trial order.

Before timing, both versions independently decoded all 12 complete 30-frame GIFs.
Case-sensitive comparison of their canonical base64 output confirmed byte equality
for every file, totalling 5,702,910 bytes per version. All timed byte counts matched
those fixtures. Historical release measurements and charts are unchanged.

## Reproducing the comparison

Compile the baseline before applying the cache, then compile the candidate with
the same SDK, dependency resolution, and unchanged harness:

```console
dart compile exe tool/dither.dart -o build/maintenance_review/dither-baseline.exe
dart compile exe tool/dither.dart -o build/maintenance_review/dither-candidate.exe
```

The second command must run after the production edit. `--fixtures-json` emits
untimed GIF bytes and verifies decoding; compare all case identifiers and
case-sensitive `gif` strings before benchmarking. `--timing-json` emits one
warmed timing sample per case without quality calculations or output collection.
The default dither report is unchanged.

```powershell
foreach ($paletteTrial in 1..9) {
  $paletteOrder = if ($paletteTrial % 2) {
    @('baseline', 'candidate')
  } else {
    @('candidate', 'baseline')
  }
  foreach ($paletteVersion in $paletteOrder) {
    & ".\build\maintenance_review\dither-$paletteVersion.exe" --timing-json |
      Set-Content -LiteralPath "build/maintenance_review/$paletteVersion-$paletteTrial.json"
    if ($LASTEXITCODE -ne 0) { throw 'Benchmark failed' }
  }
}
```

For this fixed workload, rate in Mpx/s is `256 * 256 * 30 / microseconds`.
Sort the nine rates for the median and range, then apply the gate above.
The benchmark harness SHA-256 was
`75b4ce3c81fbac6b00ce4cef5f8791940b33d0eab2ca26475d4929cb020e8a5f`.
The experiment measures these native AOT workloads; it makes no web speed claim.
