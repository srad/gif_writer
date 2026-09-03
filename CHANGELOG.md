## 0.1.0

First release: the streaming container.

- `GifWriter` writes frames to any `StreamSink<List<int>>` as they arrive, holding at most one
  255-byte LZW sub-block. Peak memory is a function of one frame, never of the animation's length.
- `GifWriter.toFile` for the common case, with `IOSink.flush` wired up so back-pressure reaches the
  caller.
- `GifWriter` implements `StreamConsumer<GifFrame>`, so `frames.pipe(writer)` works.
- Indexed frames against a caller-supplied `GifColorTable`. Byte-exact: no quantiser in the path.
- `GifRepeat.forever`, `.once` and `.times(n)`.
- No `dart:io` in the core, so the package works on the web.
- Open-addressed `Int32List` string table rather than a `Map`, one encoder reused for the whole
  animation, batched sink writes, and no per-pixel range check for a full colour table. Measured at
  25.8 Mpx/s on noise and 119.6 Mpx/s on a gradient, against 12.4 and 36.6 before — and 121 sink
  writes for a 5.8 MB animation, against 24,365.
- `bufferSize` on the constructor, for callers on a tighter memory budget than the 64 kB default.
