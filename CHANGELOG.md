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
