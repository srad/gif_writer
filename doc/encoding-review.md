# Version 0.5.0 measurements and validation

Measured on Windows x64 with Dart 3.13.2 and `image` 4.9.2, September 2026.
The changes fix invalid-file-opening side effects, concurrent sink writes,
shutdown error handling, LZW end-code widths, transparent-pixel diffusion,
and an unnecessary RGB allocation during opaque palette derivation.

## AOT comparison

The existing `tool/compare.dart` workload: 60 frames of 256×256, supplied palettes,
no quantization, median of nine interleaved trials. Both outputs are decoded and
checked against the input before timing results are reported. The saved pre-change
build was run immediately before the final implementation on the same machine.

| Workload | Before, Mpx/s | Final, Mpx/s | image, Mpx/s | Final speed advantage |
|---|---:|---:|---:|---:|
| Noise, 32 colors | 67.9 | 60.9 | 26.7 | 128% |
| Photo, 32 colors | 94.6 | 91.9 | 47.7 | 93% |
| Noise, 256 colors | 53.3 | 48.6 | 30.8 | 58% |
| Photo, 256 colors | 58.7 | 54.2 | 35.3 | 53% |

All four final wins exceeded the comparison tool's measured run-to-run spread.
The final implementation's medians were 3–10% below the saved baseline in this run;
these figures describe the entire correctness change, not an isolated queue cost.
Output sizes for these workloads were unchanged from the baseline and remained
0.8–6.4% smaller than `image`'s outputs.

The final comparison's observed ranges and output sizes:

| Workload | gif_writer range, Mpx/s | image range, Mpx/s | gif_writer output, MiB | image output, MiB |
|---|---:|---:|---:|---:|
| Noise, 32 colors | 55.5–65.1 | 25.9–27.9 | 2.91 | 3.04 |
| Photo, 32 colors | 75.5–95.0 | 42.6–48.4 | 1.13 | 1.21 |
| Noise, 256 colors | 42.3–50.6 | 27.8–31.9 | 5.15 | 5.19 |
| Photo, 256 colors | 47.9–56.5 | 31.6–36.1 | 3.34 | 3.39 |

## Retained memory

A separate VM-service probe measured live heap plus external memory after garbage
collection, using three trials per case. Shared input buffers were prepared before
the baseline snapshot. The writer used a discarding sink with a real, pending `done`
future, so per-frame listeners would have remained observable. `image` retained
its active encoder and output buffer. No decoder or output collector was retained
on the streaming path. These are live-retention measurements under the JIT, not
peak RSS, transient-allocation peaks, or AOT memory measurements.

Across the same four indexed workloads:

| Frames | gif_writer, MiB | image, MiB |
|---|---:|---:|
| 60 | approximately 0.31–0.32 | 1.92–5.77 |
| 1,000 | approximately 0.31–0.32 | 51.70–155.65 |

The writer's small variations were within a few KiB, including VM warm-up and
profiling variation; retained memory did not scale with animation length.
Unlike the former comparison tool's fixed-buffer estimate, these snapshots include live
queue, future, sink, palette, and encoder objects above the shared-input baseline.

The README memory charts show these measured medians at each frame count, on a
logarithmic axis. They do not extrapolate output size into retained memory.
The per-workload values and chart inputs are recorded in
[`benchmark-data.json`](benchmark-data.json).

With the first frame blocked in its flush, the actual implementation retained:

| Waiting RGBA frames | Additional retained memory |
|---|---:|
| 16 at 256×256 | 4.01 MiB |
| 16 at 1920×1080 | 126.57 MiB |
| 4 at 3840×2160 | 126.56 MiB |

Each queue drained all accepted frames and released its waiting buffers. Inputs
are borrowed until their futures complete. An unlimited backlog can erase the
memory advantage; awaited frame writes and `addStream` are the bounded-memory
usage paths. Views can retain backing buffers larger than their visible slices.

## Regression coverage

The added tests cover file safety and real `IOSink` concurrency on the VM;
shared tests cover queued frame order, palette derivation, input reuse, stream
ownership, recoverable input errors, terminal sink errors, and repeatable close
completion. Strict LZW parsing checks EOI inside the data payload across code-width
boundaries and dictionary resets. Transparent-dither tests cover all six dithers,
hidden RGB invariance, scan directions, threshold boundaries, and opaque RGBA/RGB
equivalence. An older empty-writer test now awaits `close()` before reading output.

Validation: **182 VM tests and 168 Chrome tests pass**, and `dart analyze` reports
no issues. The fourteen file-system and image-conversion tests are VM-only.

## Standalone throughput

Refreshed September 5, 2026 with the current implementation, AOT, 120 frames of
256×256 at 32 colors, median of nine trials. The sink counts and discards bytes;
these timings exclude disk I/O.

| Workload | Median, Mpx/s | Range, Mpx/s | Output, MiB | Sink writes |
|---|---:|---:|---:|---:|
| Noise | 63.8 | 58.1–68.7 | 5.82 | 121 |
| Photo | 81.0 | 54.4–92.8 | 2.26 | 121 |
| Smooth gradient | 128.0 | 97.2–146.4 | 0.30 | 121 |

These are separate runs from the comparison above, with twice as many frames.
Absolute rates vary with machine load; use the interleaved comparison for speed
ratios against `image`. The synthetic inputs are generated deterministically by
[`tool/sample_image.dart`](../tool/sample_image.dart), with no downloads.

## Dither tradeoffs

Refreshed September 5, 2026 using `tool/dither.dart`, AOT, 30 RGB frames of
256×256 and a supplied 27-color palette, median of five trials. Rates include
mapping and encoding. These opaque RGB measurements do not benchmark transparency
or palette derivation.

| Dither | Blurred error | Structure | Output, MiB | Rate, Mpx/s |
|---|---:|---:|---:|---:|
| `none` | 33.37 | 1226 | 0.15 | 78.2 |
| `bayer4` | 21.10 | 571 | 0.27 | 33.1 |
| `bayer8` | 21.09 | 564 | 0.28 | 32.9 |
| `blueNoise` (default) | 21.05 | 578 | 0.41 | 32.3 |
| `floydSteinberg` | 4.04 | 84 | 0.62 | 19.1 |
| `atkinson` | 9.72 | 63 | 0.57 | 15.3 |

Blurred error is RMSE after a 5×5 box blur of both images. Structure is the peak
spectral power divided by mean power over a 64×64 crop; lower values indicate less
periodic error. Neither measure alone describes visual quality.

On a flat mid-tone field, the structure scores were 4095 for both Bayer variants
and Floyd–Steinberg, 1870 for Atkinson, and 10 for blue noise. Blue noise avoids a
regular grid while keeping mapping stable at each position across frames. On the
photographic workload it costs about 50% more output bytes than Bayer. Choose
`none` for exact palette colors, Bayer for smaller files, or Floyd–Steinberg when
lower blurred error matters more than temporal stability.

## Memory and implementation notes

The indexed path's main reusable buffers are a 64 KiB staging buffer and two
32,768-entry `Int32List` LZW tables totaling 256 KiB. RGB mapping additionally
allocates a 96 KiB inverse color cube, a 5 KiB exact-color lookup, palette channel
arrays, and one byte per pixel of index scratch space. Error diffusion adds
`12 × width` bytes for two RGB error rows. RGBA conversion adds three bytes per
pixel of reusable RGB scratch space. Palette generation has its own transient
allocations. Small runtime objects are additional to these buffer sizes.

The LZW dictionary uses open addressing with an odd probe step and generation
counters to avoid clearing the table on every reset. GIF sub-blocks are written
directly into the staging buffer, which batches sink writes. These implementation
choices keep the hot path compact and reuse storage across frames.

## Reproduction

From the repository root after `dart pub get`:

```console
dart compile exe tool/compare.dart -o .dart_tool/compare.exe
dart compile exe tool/benchmark.dart -o .dart_tool/benchmark.exe
dart compile exe tool/dither.dart -o .dart_tool/dither.exe
```

Run each executable separately to avoid competing benchmark processes. Sizes use
**MiB = 1,048,576 bytes**. The former comparison tool's `held` column mixed a
buffer-size estimate for this writer with finished output size for `image`.
That misleading column has been removed; retention is measured separately using
the VM service as described above.

To reproduce retention, prepare shared inputs before a baseline post-GC VM-service
snapshot, encode 60 or 1,000 awaited frames, keep the active encoder alive, and
take another post-GC snapshot. Add live heap and external memory, subtract the
baseline, and report the median of three trials. Use a discarding streaming sink
whose `done` stays pending until close; keep `image`'s unfinished encoder alive.

The chart renderer needs Python with Matplotlib and NumPy. Run
`python tool/charts.py` to generate both light and dark variants from the saved
[`benchmark-data.json`](benchmark-data.json) measurements. Update that file after
a new comparison or retention measurement; rendering does not run benchmarks.
