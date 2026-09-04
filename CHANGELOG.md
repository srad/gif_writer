## 0.3.0

The encoder now chooses a palette for you. Someone holding a photo or a video frame has RGB and no
palette; until now they had to build a `GifColorTable` by hand, and a bad guess was dithered onto
faithfully. **The indexed path is untouched** — byte-identical to 0.2.x — and `colors:` still works
exactly as before; everything here is additive.

### Added

- **`GifColorTable.quantize(rgb, {maxColors, quantizer})`** derives a table from raw pixels.
- **`GifWriter`'s `colors:` is now optional.** Left unset, the writer quantises the **first** RGB or
  RGBA frame into one global table and maps the rest of the animation onto it — so the streaming
  guarantee holds: the palette comes from the one frame already in hand, nothing is accumulated. An
  RGBA first frame is composited before it is quantised. An *indexed* first frame cannot derive a
  table and is refused with a clear error rather than a crash.
- **Two quantisers, behind `GifQuantizer`.** `octree` (the default) holds no more than the palette —
  a few hundred nodes reduced as the image streams in, freed before a frame is written — which is why
  it is the default in a package whose whole claim is a small, fixed overhead. `wu` (Xiaolin Wu's
  greedy orthogonal bipartitioning) scores a little higher on fidelity for a transient ~1.4 MB moment
  histogram, freed the same way. `tool/quantize.dart` measures the two rather than asserting the
  trade-off; on a 256×256 photographic frame Wu came in at RMS 1.78 against octree's 2.06.
- A writer left to derive its table but closed with **no** frames now writes a valid header with no
  global colour table, keeping the zero-frame guarantee even when no palette was ever chosen.

### Notes

- The palette is **global** — one table for the animation, derived from the first frame. Later frames
  map onto it, so a scene whose colours shift partway through is mapped onto the first frame's palette;
  quantise a representative image yourself and pass it as `colors:` when that is not what you want.
  Per-frame palettes need local colour tables and wait for 0.4.0's frame diffing.
- Both quantisers are exercised on the VM and under Chrome; Wu's moment tables are `Float64List`
  precisely so its sums stay exact where `int` is a `double`.

## 0.2.1

Two defects and a test that was not testing what it said. **Output is byte-identical to 0.2.0** on
every workload — verified by fingerprinting the encoded bytes of six benchmark workloads plus a
70-frame animation, before and after every change here.

### Fixed

- **`GifRepeat.times(n)` above 65536 silently wrote the wrong loop count.** The Netscape block counts
  plays in two bytes, so `times(70000)` stored 69999 and emitted its low sixteen bits — a file that
  asks for 4463 plays, decodes perfectly, and is wrong in the one way a round-trip test cannot see.
  The same shape as the `times(1)` bug in 0.1.1. It now throws rather than truncating, which is
  breaking only for callers who were already getting a file they did not ask for.
- **The test named "large enough to refill the dictionary" never refilled the dictionary.** Its
  pattern compressed so well that 40,000 pixels came to under 4,096 codes, so `_nextCode` never
  reached the limit and the dictionary-full path — the one most able to produce a silently corrupt
  file — had no working test at all. Confirmed by tampering: corrupt that path and the test still
  passed. It now uses seeded pseudo-noise, which refills four times over at the same size, and it
  fails when that path is broken.
- The looping block is chosen on `count`, not on identity with `GifRepeat.once`, which held only
  while `once` was the sole instance carrying a negative count.
- The README's headline "held in memory" figure said 0.06 MB against its own overhead table's
  ~192 kB three sections below. 0.06 MB was the largest single sink handover — the staging buffer
  alone, blind to the 128 kB LZW table held just as permanently. Both now read 0.19 MB.

### Changed

- **The LZW string table is retired by a generation counter instead of being zeroed.** The dictionary
  resets far more often than once per frame — measured at 256x256, ten times a frame on noise at 32
  colours and seventeen at 256 — and each reset zeroed 64 kB. Slots now carry an epoch, so a reset is
  an increment and the table is genuinely cleared only every 1023 generations.
  Measured on `tool/benchmark.dart`, AOT (`dart compile exe`), interleaved against 0.2.0: **+47% on
  noise, +26% on photo, +24% on a gradient.** Under the JIT the same comparison is inside the
  run-to-run spread and is not claimed. Encoded bytes are unchanged either way.
- Minimum SDK is now 3.7, so `dart format` applies the tall style this package is written in. Callers
  on 3.4 to 3.6 resolve to 0.2.0 and are otherwise unaffected.

### Added

- A round-trip test over an animation long enough to recycle the LZW generation counter — a branch
  that would otherwise first run about sixty frames into a real recording.

## 0.2.0

RGB and RGBA input, mapped onto the colour table you supply, with five dithers. **The indexed path is
byte-for-byte unchanged** — pinned by a golden fixture captured from 0.1.0 before any of this existed.

### Added

- `addRgbFrame` (three bytes per pixel) and `addRgbaFrame` (four, composited over a **required**
  `background`, because transparency is not implemented yet and silently dropping alpha would give a
  wrong colour rather than an obvious error).
- `GifDither.blueNoise` (default), `.bayer4`, `.bayer8`, `.floydSteinberg`, `.atkinson` and `.none`.
- `GifFrame.rgb` and `GifFrame.rgba`, so `frames.pipe(writer)` accepts everything the direct calls do.
- A pixel that is *exactly* a table colour always maps to that entry, so palettised content survives
  the RGB path unchanged.

### Why the default is an ordered dither

Floyd–Steinberg makes the best single image and is wrong for an animation: it carries error between
pixels, so one pixel changing by one level changes every pixel after it. Static regions then decode
differently frame to frame, the noise defeats LZW, and no region is ever byte-identical, which rules
out frame diffing. An ordered dither reads its threshold from position alone, so a one-pixel change
affects exactly one pixel — which has a test on it rather than a claim in a comment.

Blue noise over Bayer was **measured, not assumed**, and the first metric got it wrong. Blurred RMSE
rates the two identically, because blurring destroys the high-frequency structure that is exactly
where an ordered dither's artefact lives. On a flat field, where the only structure is the dither's
own, Bayer scores 4095 — a pure periodic grid — against blue noise's 10. It costs about 50% more
bytes; `bayer4` remains there for callers who want the smaller file.

### Memory

Unchanged for indexed callers at ~192 kB. RGB adds a 96 kB inverse colour cube, and error diffusion
two rows of error at `12 × width` — allocated on the first RGB frame, never for an indexed-only
animation, and never per frame.

### Fixed

- The README's benchmark charts now use absolute URLs. pub.dev renders `<img>` only when it can
  resolve the URL, so the relative `doc/…` paths in 0.1.0 were stripped to their alt text and both
  charts showed as bracketed prose on the package page. GitHub resolves them fine, which is what hid
  it until after publishing.

## 0.1.0

First release: a high-performance, low-memory streaming GIF encoder.

### Writing

- `GifWriter` compresses and writes each frame to any `StreamSink<List<int>>` as it arrives. Peak
  memory is a function of one frame, never of the animation's length — about 190 kB of fixed
  overhead, whether the result is 10 frames or 10,000.
- `GifWriter.toFile` for the common case, with back-pressure wired to `IOSink.flush`, so a producer
  faster than the disk cannot queue frames inside the sink.
- `GifWriter` implements `StreamConsumer<GifFrame>`, so `frames.pipe(writer)` consumes a stream
  without collecting it.
- Indexed frames against a caller-supplied `GifColorTable`. Byte-exact: no quantiser in the path.
- `GifRepeat.forever`, `.once` and `.times(n)`.
- `bufferSize` for callers on a tighter budget than the 64 kB default, floored at
  `GifWriter.minBufferSize` — a buffer that could fill mid-block would let a sub-block's length byte
  be patched at a stale position, which is a corrupt file with nothing thrown.
- No `dart:io` in the core, so the package and its tests run on the web.

### Performance

Measured against `package:image` on identical pre-palettised input, as the **median of nine
interleaved trials**, with both outputs decoded and checked pixel-for-pixel before any timing is
reported. **1.5–1.9× faster on every workload measured**, each gap wider than the spread of either
encoder, and the output smaller every time. The throughput figures are one run on one machine and the
ratios move a few points between runs; the file sizes are byte-identical every time.

| workload | gif_writer | `package:image` |
| :-- | --: | --: |
| photo · 32 colours | **82.2 Mpx/s**, 1.13 MB | 48.1 Mpx/s, 1.21 MB |
| photo · 256 colours | **53.7 Mpx/s**, 3.34 MB | 35.8 Mpx/s, 3.39 MB |
| noise · 32 colours | **56.1 Mpx/s**, 2.91 MB | 30.2 Mpx/s, 3.04 MB |
| noise · 256 colours | **46.5 Mpx/s**, 5.15 MB | 29.2 Mpx/s, 5.19 MB |

And **0.06 MB held against 5.19 MB** at 60 frames — against ~87 MB at 1000, where this package still
holds 0.06.

> **Correction, 0.2.1:** that 0.06 MB was wrong. It is the largest single handover to the sink — the
> 64 kB staging buffer — and it misses the 128 kB LZW string table, which is held just as
> permanently. The real figure is **0.19 MB**, and it is still flat at any length. Left in place
> rather than rewritten, so the record shows what was claimed at the time.

What earns it, each measured rather than assumed:

- An open-addressed `Int32List` string table rather than a `Map`, at a 0.25 load factor. The classic
  5003 slots puts 4096 codes at 0.82 and probes several times per pixel.
- A hash that every key can actually address. The `(pixel << 4) ^ prefix` of the classic C
  implementations cannot exceed 4095 below 256 colours, so most of the table is unreachable and the
  load factor is really 1.0; mixing the key properly took noise from 27.2 to 59.7 Mpx/s.
- A power-of-two table probed with an **odd** displacement — coprime to the size, so it still visits
  every slot, with no division per pixel. Two other shapes were tried and lost: linear probing ran
  **36× slower**, and a prime table with `key % size` measured 86.8 Mpx/s on a gradient against 142.9.
- Sub-blocks written straight into the staging buffer, the length byte reserved and patched
  afterwards, which removes a copy of the entire compressed output.
- Batched sink writes: 121 for a 5.8 MB animation, against 24,365 when each sub-block went through
  on its own.
- One encoder reused for the whole animation rather than allocating its tables per frame.
- No per-pixel range check for a full colour table, where no byte can be out of range. Elsewhere the
  check ORs the bytes together and only walks precisely if that suggests trouble.

### Correctness

44 tests, on the VM and under Chrome. Round trips are verified against `package:image` — a separate
implementation, deliberately — at 1×1, single-row, single-column, non-multiple-of-eight and
dictionary-refilling sizes, and with a full 256-colour table. The streaming guarantee is verified by
tampering: make the writer accumulate, and its tests fail.

One defect found that way and fixed before release: `GifRepeat.times(1)` looped **forever**, because
the field counts *additional* plays and one play became zero — which is the code for endless. Every
pixel decoded perfectly, so only a test that reads the Netscape block could see it.
