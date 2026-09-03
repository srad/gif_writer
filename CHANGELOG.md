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
