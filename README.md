<h1 align="center">gif_writer</h1>

<p align="center">
  <strong>A streaming GIF encoder for Dart.</strong><br>
  Frames go out as they arrive, so memory stays flat however long the animation runs.
</p>

<p align="center">
  <a href="https://pub.dev/packages/gif_writer"><img src="https://img.shields.io/pub/v/gif_writer.svg?logo=dart&logoColor=white" alt="pub package"></a>
  <a href="https://pub.dev/packages/gif_writer/score"><img src="https://img.shields.io/pub/points/gif_writer?logo=dart&logoColor=white" alt="pub points"></a>
  <a href="https://pub.dev/packages/gif_writer/score"><img src="https://img.shields.io/pub/likes/gif_writer?logo=dart&logoColor=white" alt="likes"></a>
  <a href="https://github.com/srad/gif_writer/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT licence"></a>
  <img src="https://img.shields.io/badge/SDK-%E2%89%A5%203.4-0175C2?logo=dart&logoColor=white" alt="Dart SDK 3.4+">
  <img src="https://img.shields.io/badge/platforms-all-success" alt="all platforms">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="no dependencies">
</p>

---

## The problem

Every GIF encoder available for Dart builds the finished file in memory and hands it back at the end.
That is fine for a six-frame spinner. It is unworkable for anything long:

```
                       peak memory
                       ────────────────────────────────────────────
  buffering encoder    ████████████████████████████████  ~105 MB
  gif_writer           ▏                                 ~100 kB
                       ────────────────────────────────────────────
                       1000 frames at 512x512
```

Nothing in the format requires it. A GIF is a header, a colour table, self-contained per-frame blocks,
and a one-byte trailer — **no frame count in the header, no index, nothing to backpatch.** It is a
naturally streamable container. This package writes it that way.

```
 frame ─► LZW ─► 255-byte sub-block ─► 64 kB staging buffer ─► your sink
                 (reused)              (reused, flushed per frame)
```

Peak memory is a function of **one frame**, never of the animation's length.

## Install

```console
dart pub add gif_writer
```

## Quick start

```dart
import 'package:gif_writer/gif_writer.dart';

final gif = GifWriter.toFile(
  'out.gif',
  width: 256,
  height: 256,
  colors: GifColorTable.packed(<int>[0x000000, 0xFF5500, 0xFFFFFF]),
);

for (final frame in frames) {
  await gif.addIndexedFrame(frame, delay: const Duration(milliseconds: 50));
}
await gif.close();
```

`frame` is one byte per pixel — an index into the colour table you supplied. No quantiser sits in the
path, so what you put in is what decodes out, byte for byte.

## Recipes

<details open>
<summary><strong>Pipe a stream of frames</strong></summary>

`GifWriter` is a `StreamConsumer<GifFrame>`, so frames are consumed as they are produced and never
collected into a list.

```dart
await frames.pipe(
  GifWriter.toFile('out.gif', width: w, height: h, colors: colors),
);
```
</details>

<details>
<summary><strong>Write to any sink — a socket, a buffer, the web</strong></summary>

The core imports no `dart:io`, so it runs anywhere Dart does.

```dart
final gif = GifWriter(
  socket,                 // any StreamSink<List<int>>
  width: w,
  height: h,
  colors: colors,
  onFlush: () => socket.flush(),
);
```
</details>

<details>
<summary><strong>Control looping</strong></summary>

```dart
GifWriter.toFile(..., repeat: GifRepeat.forever);   // the default
GifWriter.toFile(..., repeat: GifRepeat.once);      // no looping block at all
GifWriter.toFile(..., repeat: GifRepeat.times(3));  // play three times
```
</details>

<details>
<summary><strong>Trim the memory further</strong></summary>

```dart
GifWriter(sink, ..., bufferSize: 4 * 1024);
```

The staging buffer is the package's whole fixed overhead besides the LZW tables. Below about a
kilobyte the syscalls cost more than the buffer saves.
</details>

## Benchmarks

### Against `package:image`

60 frames of 256×256, run with [`tool/compare.dart`](tool/compare.dart). Both encoders are given
frames that **already carry a palette**, so neither quantises — otherwise `image` would be paying for
NeuQuant this package does not implement, and the comparison would say nothing. The tool decodes both
outputs and checks them pixel-for-pixel against the input before printing a single number; it refuses
to report timings if either is wrong.

| | throughput | largest single handover | output size |
| --- | ---: | ---: | ---: |
| **gif_writer** — 256 colours | **41.0 Mpx/s** | **0.06 MB** | **5.15 MB** |
| `package:image` — 256 colours | 32.3 Mpx/s | 5.19 MB | 5.19 MB |
| **gif_writer** — 32 colours | 29.7 Mpx/s | **0.05 MB** | **2.91 MB** |
| `package:image` — 32 colours | 29.4 Mpx/s | 3.04 MB | 3.04 MB |

Read honestly: **about 25% faster with a full palette, and level at 32 colours** — there the
run-to-run spread is wider than the gap, so calling it a win would be overstating it. Files come out
slightly smaller, 4% at 32 colours.

The number that is not close is the third column. `package:image` hands over the finished file in one
piece, so what it holds *is* the file; this package hands over a fixed staging buffer. At 60 frames
that is 5.19 MB against 0.06 MB. At 1000 frames it would be ~100 MB against the same 0.06 MB, because
one side scales with the animation and the other does not.

### On its own

120 frames of 256×256 at 32 colours, [`tool/benchmark.dart`](tool/benchmark.dart):

| workload | throughput | sink writes | output |
| --- | ---: | ---: | ---: |
| noise — worst case for LZW | **29.2 Mpx/s** | 121 | 5.82 MB |
| smooth gradient | **144.7 Mpx/s** | 121 | 0.30 MB |

### Where the speed comes from

Fixed overhead is about 140 kB and does not grow: a 64 kB staging buffer plus a 78 kB LZW string
table, both allocated **once for the whole animation** rather than per frame.

| | |
| --- | --- |
| **Open-addressed `Int32List` string table** | not a `Map<int, int>`. Probed once per pixel, the hottest loop here. |
| **A hash sized for a 0.41 load factor** | the classic 5003 slots puts 4096 codes at 0.82 load and probes several times per pixel; 9973 measured ~20% faster. Larger plateaus, then loses to the cost of clearing it. |
| **Batched sink writes** | passing every 255-byte sub-block straight through cost **24,365** sink calls for a 5.8 MB animation. Batching makes it 121. |
| **Sub-blocks written in place** | the length byte is reserved and patched afterwards, so compressed bytes are never staged in a scratch array and copied — that copy is a `memcpy` of the entire output. |
| **No per-pixel range check at 256 colours** | where no byte *can* be out of range. Elsewhere the check ORs the bytes together and only walks precisely if that suggests trouble — 2.6% rather than a second pass. |

Two changes that looked obviously good and measured worse, kept here so nobody repeats them: a
power-of-two hash with linear probing ran **36× slower** — the displacement probe needs a step coprime
to the table size, and clustering did the rest — and enlarging the hash past ~10,000 slots costs more
in clearing than it saves in probing.

## API

| | |
| --- | --- |
| `GifWriter(sink, …)` | Writes to any `StreamSink<List<int>>`. |
| `GifWriter.toFile(path, …)` | Convenience for `dart:io`, with back-pressure wired to `IOSink.flush`. |
| `addIndexedFrame(indices, delay:)` | One byte per pixel. Validated, then compressed straight out. |
| `addStream(stream)` / `pipe` | Consume a `Stream<GifFrame>`. |
| `close()` | Writes the trailer and closes the sink. |
| `GifColorTable.packed([0xRRGGBB, …])` | Up to 256 colours. |
| `GifColorTable.rgb([r, g, b, …])` | The same, as raw bytes. |
| `GifRepeat.forever` / `.once` / `.times(n)` | Looping. |

### Back-pressure matters

`addIndexedFrame` awaits the sink once per frame. Without that the buffering would simply move one
layer down — a producer faster than the disk would queue frames *inside* the sink, using the same
memory somewhere much harder to notice. `GifWriter.toFile` handles this for you; pass `onFlush`
yourself for other sinks.

### Delays are hundredths of a second

That is all the format stores. A `Duration` is rounded to the nearest hundredth, and **most viewers
refuse delays below two hundredths**, silently substituting ten. A 60 fps GIF is not something GIF can
express; this package writes what you ask for rather than pretending otherwise.

## Scope

**0.1.0 takes indexed frames**: you bring the colour table, one byte per pixel. That is exactly what
the format needs, and it is lossless — no quantiser, so the round trip is byte-exact.

| version | |
| --- | --- |
| **0.1.0** ✅ | Streaming container, LZW, indexed frames, any sink |
| 0.2.0 | Octree quantisation and RGBA input, global or per-frame palettes |
| 0.3.0 | Dithering, transparency, disposal methods |
| 0.4.0 | Frame diffing — write only the changed rectangle |

Quantisation is deliberately not first: it is the part with a memory cost of its own, and getting the
streaming container right matters more than accepting more input formats early.

## Testing

Round trips are verified against [`package:image`](https://pub.dev/packages/image) — a **separate
implementation**, deliberately. Checking an encoder against its own decoder proves only that the two
share a misunderstanding.

The streaming guarantee has tests of its own, and those are verified *by tampering*: make the writer
accumulate, and they must fail. A guard never seen red is not known to guard anything.

Covered: 1×1, single-row and single-column frames, non-multiples of eight, a frame large enough to
refill the LZW dictionary, and a full 256-colour table — the sizes where block boundaries and code
widths go wrong. Everything runs on the VM and under Chrome.

## Licence

MIT © [Saman Sedighi Rad](https://github.com/srad) — see [LICENSE](LICENSE).
