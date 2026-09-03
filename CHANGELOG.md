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
- Size the LZW hash for a 0.41 load factor (9973 slots, prime) rather than the classic 5003 at 0.82.
  Measured ~20% faster; a power-of-two table with linear probing, tried first, was **36x slower**
  because the displacement probe needs a step coprime to the size.
- Write sub-blocks straight into the staging buffer, reserving the length byte and patching it, which
  removes a copy of the entire compressed output.
- Refuse a `bufferSize` below `GifWriter.minBufferSize`. A buffer that could fill mid-block would let
  the length byte be patched at a stale position — a corrupt file with nothing thrown.
- **Fix `GifRepeat.times(1)`, which looped forever.** The stored value is the number of *additional*
  plays, so one play became `_(0)`, and zero is the code for endless. Caught by a new test; nothing
  about the file looked wrong.
- Tests for the colour table's power-of-two padding and exponent, the staging buffer at its minimum
  size, block-boundary frame sizes, and every looping mode.
