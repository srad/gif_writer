# Roadmap

What is done, what is next, and what was deliberately left alone. Items reference files and symbols
rather than line numbers, which move.

State: `[x]` done · `[ ]` open · `[~]` decided against, with the reason.

---

## Shipped

### 0.1.0
- [x] Streaming container, LZW, indexed frames, any `StreamSink<List<int>>`

### 0.2.0
- [x] RGB and RGBA input mapped onto a supplied table, with five dithers

### 0.2.1
- [x] `GifRepeat.times(n)` above 65536 refused rather than truncated
- [x] The dictionary-refill round-trip test actually refills the dictionary
- [x] Round-trip test crossing the LZW generation recycle
- [x] LZW string table retired by an epoch counter instead of a 64 kB zeroing per reset
- [x] `dart format` clean; SDK floor 3.7
- [x] Held-memory figure reconciled at 0.19 MB across README and `tool/charts.py`
- [x] Dead members removed (`BufferedByteSink.flushedBytes`, `ColorMapper.length`)

---

## Next — small, no API change

- [ ] **CI.** There is none, and everything it would run is green today: `dart analyze`,
      `dart format --set-exit-if-changed`, `dart test`, `dart test -p chrome`, and the example.
      The README asserts "everything runs on the VM and under Chrome" with nothing enforcing it.
      This is the highest-value open item: every guard in this package is only as good as something
      running it.
- [ ] **Re-measure `_hashSize`.** The 8192 / 16384 / 32768 table in `lib/src/lzw.dart` was measured
      when every reset zeroed the table. That cost is gone, so the comparison that chose 16384 no
      longer holds and a larger table may now win — clearing is nearly free between frames. The
      doc-comment says so; the numbers still need redoing.
- [ ] **Benchmark methodology: report AOT.** `tool/benchmark.dart` and `tool/compare.dart` run under
      the JIT, which swung ±13% run-to-run on the same code while this was being measured — wide
      enough to hide a real 25% change. AOT (`dart compile exe`) was tight and reproducible, and is
      also how a Flutter release build actually runs this package. Either switch the tools to AOT or
      report both.
- [ ] **`compare.dart` measures the wrong memory.** `CountingSink.peakHeld` records the largest
      single handover to the sink, which is the staging buffer alone — it cannot see the 128 kB LZW
      table held just as permanently. That is where the README's wrong 0.06 MB came from. Report the
      encoder's true fixed overhead instead.
- [ ] **Document the concurrency guarantee.** Concurrent `add*Frame` calls are safe, because every
      mutation of `_scratch`, `_lzw` and `_out` happens synchronously before the single
      `await _onFlush`. That is not obvious and nothing states it; a future `await` moved earlier
      would silently break it.
- [ ] **`GifColorTable.rgb` truncates silently.** It takes `List<int>` and hands it to
      `Uint8List.fromList`, so a caller passing values outside 0–255 gets them wrapped rather than
      rejected. `GifColorTable.packed` masks deliberately; this one should validate.
- [ ] Consider `lints: ^5.0.0` (needs Dart ^3.5.0, so it fits the 3.7 floor; `^6.0.0` needs ^3.8.0).

## Structural — changes public API shape, needs a decision

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
- [ ] **`==` / `hashCode` on `GifColorTable`, `GifRepeat`, `GifDither`.** All three are value-like
      and public, and `GifColorTable` is the one a caller would naturally compare or key on.
- [ ] **Expose `GifWriter.done`.** Sink errors currently reach the caller only through `close()` or
      `onFlush`. Fine for `toFile`; thin for the "write to a socket" recipe the README advertises.

## Performance — measured, not assumed

- [ ] **Packed palette in `ColorMapper`.** `_mapOrdered` takes six bounds-checked loads per pixel
      (`redAt`/`greenAt`/`blueAt` twice); `_mapDiffused` takes three. A `Uint32List` of packed
      colours — 1 kB against the 96 kB cube already there — makes those two and one. Affects the RGB
      paths only. `tool/dither.dart` already reports a rate per dither, so it is directly measurable.
      Note that reusing `colorAt` does **not** help: it does the same three loads internally.

## Features

### 0.3.0
- [ ] Octree quantisation — deriving the palette, global or per frame.
      Deliberately not first: it is the part with a memory cost of its own, and getting the streaming
      container and the mapping right mattered more than accepting more input formats early.
- [ ] When per-frame palettes arrive, `ColorMapper`'s cube and exact-colour table must be invalidated
      alongside the LZW dictionary. Nothing is cleared between frames today because the palette is
      fixed for a writer's lifetime.

### 0.4.0
- [ ] Transparency and disposal methods. `addRgbaFrame`'s required `background` exists only because
      transparency is not implemented; it becomes optional once it is.
- [ ] Frame diffing, using the image descriptor's left/top and a local colour table. The ordered
      dithers were chosen partly to make this possible — static regions stay byte-identical frame to
      frame, which error diffusion would destroy.

---

## Decided against

- [~] **Floyd–Steinberg as the default dither.** It boils, it defeats LZW, and it rules out frame
      diffing. Measured in `tool/dither.dart`; see the `GifDither` docs.
- [~] **A peak-RSS test for the streaming guarantee.** `ProcessInfo.currentRss` is GC-dependent and
      would be flaky, and a flaky test guarding the one property that matters is worse than none.
      The deterministic structural tests in `test/streaming_test.dart` prove the same thing.
- [~] **A prime LZW hash table, and linear probing.** Both measured worse; recorded in `lzw.dart` so
      nobody repeats them.
- [~] **Splitting `lzw.dart`'s measurement tables into `doc/`.** The comments are load-bearing —
      they record dead ends with numbers — and the file stays readable. Revisit only if it grows.
