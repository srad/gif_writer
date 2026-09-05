# Roadmap

What is done, what is next, and what was deliberately left alone. Items reference files and symbols
rather than line numbers, which move.

State: `[x]` done · `[ ]` open · `[~]` decided against, with the reason.

---

## Release history

Measurements in older entries describe those releases, not the current build.

### 0.1.0
- [x] Streaming container, LZW, indexed frames, any `StreamSink<List<int>>`

### 0.2.0
- [x] RGB and RGBA input mapped onto a supplied table, with five dithers plus `none`

### 0.2.1
- [x] `GifRepeat.times(n)` above 65536 refused rather than truncated
- [x] The dictionary-refill round-trip test actually refills the dictionary
- [x] Round-trip test crossing the LZW generation recycle
- [x] LZW string table retired by an epoch counter instead of a 64 kB zeroing per reset
- [x] `dart format` clean; SDK floor 3.7
- [x] Held-memory figure reconciled at 0.19 MB across README and `tool/charts.py`
- [x] Dead members removed (`BufferedByteSink.flushedBytes`, `ColorMapper.length`)
- [x] `GifDither.blueNoise` takes its side from `blueNoiseSide` rather than a literal 64
- [x] Corrected comments that described code which did not exist (`ColorMapper.colorAt`), the wrong
      type (`Uint8List` for the blue-noise table, in the generator too), and the wrong symbol
      (`compare.dart`'s file doc, which dartdoc bound to `CountingSink`)

### 0.3.0
- [x] Global palette derivation. `GifColorTable.quantize` derives a table from RGB pixels, and
      `GifWriter`'s `colors:` is now optional — left unset, it quantises the first RGB/RGBA frame into
      the global table. Two engines behind `GifQuantizer`: octree (`octree.dart`, the default, memory
      bounded by the palette) and Wu (`wu.dart`, higher fidelity for a transient 33³ histogram),
      dispatched from `quantizer.dart` and measured against each other in `tool/quantize.dart`.
- [x] A table-less writer closed with no frames writes a valid header with **no** global colour table,
      keeping the zero-frame guarantee even when nothing was ever derived.

### 0.3.1
- [x] **LZW hash table enlarged to 32768.** Re-measured AOT across 8192 / 16384 / 32768 / 65536
      (separate `dart compile exe` builds, interleaved): 32768 wins noise and photo now that
      epoch-stamped clearing made a bigger table nearly free; 65536 loses the noise win to cache
      pressure. Indexed output byte-identical; held memory 0.19 → 0.31 MB, still flat at any length.
- [x] **Benchmarks report AOT.** `tool/benchmark.dart` and `tool/compare.dart` build with
      `dart compile exe` (JIT kept as a documented quick path); the README's throughput, comparison
      and memory numbers are regenerated as AOT medians. Fixed a stale hardcoded `0.06 MB` label in
      the memory chart, blind to the value beside it (the deeper `compare.dart` `peakHeld` fix landed
      in 0.3.2).

### 0.3.2
- [x] **`GifWriter.done`, and `close()` awaits it.** Forwards the sink's `done`, so an out-of-band sink
      error — a dropped socket, reported after the `add` that caused it returned — reaches a streaming
      caller; `close()` awaits it too, so a caller who only awaits `close()` still sees it. The piece
      the README's "write to a socket" recipe was missing.
- [x] **Value equality on `GifColorTable`, `GifRepeat`, `GifDither`.** `==` / `hashCode` over their
      contents — colours+length, play count, and kind+side+matrix — so a caller can compare them or
      key a cache on them.
- [x] **`compare.dart` reports the true fixed overhead.** `CountingSink.peakHeld` measured the largest
      single handover — the staging buffer alone, ~0.06 MB — and could not see the 256 kB LZW table
      held just as permanently. `runOurs` now reports 64 kB + 256 kB = 0.31 MB, flat at any length and
      matching the README; the dead `peakHeld` is gone.
- [x] Documented the then-current synchronous buffer mutation behavior. That explanation did not
      guarantee ordered sink flushes; 0.5.0 replaces it with an explicit queue through each flush.
- [x] **`GifColorTable.rgb` confirmed already validating** each channel to 0–255 (the roadmap item was
      stale); no code change.

### 0.4.0
- [x] **Binary transparency and disposal methods.** `GifTransparency`, passed as `GifWriter`'s
      `transparency:`, reserves one palette slot as the transparent index and marks every frame with the
      transparent flag and a `GifDisposal` (default `restoreBackground`). A pixel whose alpha is below
      `alphaThreshold` (default 128) becomes a hole rather than a colour — GIF has no partial alpha, so
      this thresholds rather than blends. A supplied table must leave the slot free (≤255 colours, else
      an `ArgumentError`); a derived one quantises to 255 **from the opaque pixels only**, so invisible
      colours do not spend palette entries, with a full-buffer fallback for an all-transparent first
      frame. `ColorMapper` gained a `mapCount` so no opaque pixel is ever mapped onto the reserved
      index. `GifWriter.transparentIndex` exposes it for `addIndexedFrame` callers. New
      `transparency.dart`; verified in `test/transparency_test.dart` against `package:image` on the VM
      and under Chrome.
- [x] **`addRgbaFrame`'s `background` is now optional** — and `GifFrame.rgba`'s — since alpha can punch
      holes instead of compositing. Existing calls that pass `background:` are byte-for-byte unchanged.

### 0.5.0

- [x] Validate dimensions and transparent palette capacity before `toFile` opens a destination.
- [x] Queue concurrent frame writes through the awaited flush, borrowing inputs until their futures
      complete. Awaited frames and `addStream` retain bounded memory; concurrent backlogs retain inputs.
- [x] Make `close()` drain accepted frames and share one completion, close the sink after failures,
      and preserve the original error without retrying failed output. Observe sink `done` once.
- [x] Enforce exclusive stream consumption and keep invalid frames recoverable.
- [x] Emit the LZW end code at the decoder's final code width, with strict termination regressions.
- [x] Resolve transparent indices during dithering so hidden RGB cannot diffuse into visible pixels.
- [x] Reuse the RGB buffer when every pixel of the first transparent RGBA frame is opaque.
- [x] Confirm the speed and retained-memory advantage against `image` 4.9.2; measurements and
      validation scope are recorded in `doc/encoding-review.md`.
- [x] Refresh the concise README, benchmark charts, publication contents, and failure-safe examples.
- [x] Add a single-image conversion recipe with tests for pixel formats, alpha, orientation, and errors.

---

## Next — small, no API change

- [ ] **CI.** Add automated analysis, VM and Chrome tests, and example smoke checks.
      File-system tests run only on the VM; current release checks are performed locally.
- [ ] Review lint upgrades compatible with the Dart 3.7 SDK floor. This release keeps the existing
      dependency constraints.

## Structural — internal refactoring candidates

- [ ] **Split `BufferedByteSink`.** Its documented job is "gathers small writes", but half its
      surface (`beginBlock`, `endBlock`, `rewindTo`, `blockIsFull`) is GIF's sub-block protocol and
      `minCapacity` exists only to serve it. The result is that `GifWriter.minBufferSize` documents a
      GIF constraint by forwarding a constant from a class claiming not to know about GIF. Either
      rename it or lift the block protocol into a thin type over it.
- [ ] **Inject the sink into `GifLzwEncoder`.** It currently arrives per `encode()` call into a
      `late` field, though one writer owns one encoder and one sink for its whole life.
- [ ] **Move `GifRepeat` out of `writer.dart`** into `repeat.dart`. It is exported public API with
      nothing to do with writing mechanics; `GifDither`, `GifColorTable` and `GifFrame` each have
      their own file.

## Performance — measured, not assumed

- [ ] **Packed palette in `ColorMapper`.** `_mapOrdered` takes six bounds-checked loads per pixel
      (`redAt`/`greenAt`/`blueAt` twice); `_mapDiffused` takes three. A `Uint32List` of packed
      colours — 1 kB against the 96 kB cube already there — makes those two and one. Affects the RGB
      paths only. `tool/dither.dart` already reports a rate per dither, so it is directly measurable.
      Note that reusing `colorAt` does **not** help: it does the same three loads internally.

## Features

### Future releases — not yet scheduled
- [ ] Frame diffing, using the image descriptor's left/top and a local colour table. The ordered
      dithers were chosen partly to make this possible — static regions stay byte-identical frame to
      frame; error diffusion can change pixels outside the edited region.
- [ ] Per-frame palettes, which the local colour tables above make possible. 0.3.0 derives one
      **global** palette from the first frame; a per-frame palette needs a local table per frame, and
      when that lands `ColorMapper`'s cube and exact-colour table must be invalidated when the palette
      changes. The mapper currently stays valid for the global palette's lifetime; the LZW dictionary
      already resets for each frame.

---

## Decided against

- [~] **Floyd–Steinberg as the default dither.** Error propagation can introduce temporal shimmer,
      enlarge output, and reduce the unchanged regions available for frame diffing. Measured in
      `tool/dither.dart`; see the `GifDither` docs.
- [~] **A peak-RSS unit test for the streaming guarantee.** `ProcessInfo.currentRss` depends on GC
      and process state. Structural tests cover frame handover and back-pressure; separate post-GC
      VM-service measurements cover live retention. Neither is a measurement of peak RSS.
- [~] **Interlacing.** The image descriptor's interlace flag (`_descriptor[9]`, bit 6) stays clear.
      Rarely wanted for a modern encoder and low value: it helps only a decoder rendering a partial
      download progressively, which nothing this package targets does. Flip the bit and reorder the
      rows if a use ever appears.
- [~] **A prime LZW hash table, and linear probing.** Both measured worse; recorded in `lzw.dart` so
      nobody repeats them.
- [~] **Splitting `lzw.dart`'s measurement tables into `doc/`.** The comments are load-bearing —
      they record dead ends with numbers — and the file stays readable. Revisit only if it grows.
