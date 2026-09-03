<h1 align="center">gif_writer</h1>

<p align="center">
  <strong>A high-performance, low-memory GIF encoder for Dart.</strong><br>
  Frames are compressed and written out as they arrive, so memory stays flat<br>
  however long the animation runs — and it is faster than the alternative while doing it.
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

## At a glance

Against [`package:image`](https://pub.dev/packages/image), the only other GIF encoder for Dart.
60 frames of 256×256, both given pre-palettised input so neither quantises. **Median of nine
interleaved trials**, with the observed range beside it:

| | throughput | range | held in memory | output |
| :-- | --: | --: | --: | --: |
| **gif_writer** · 256 colours | **37.9 Mpx/s** | 36.6 – 39.8 | **0.06 MB** | **5.15 MB** |
| `package:image` · 256 colours | 30.3 Mpx/s | 29.0 – 30.8 | 5.19 MB | 5.19 MB |
| **gif_writer** · 32 colours | 26.9 Mpx/s | 26.4 – 27.7 | **0.05 MB** | **2.91 MB** |
| `package:image` · 32 colours | 28.8 Mpx/s | 27.2 – 29.6 | 3.04 MB | 3.04 MB |

**25% faster with a full palette** — a gap well outside both spreads. At 32 colours the two are
**level**: `package:image`'s median is a shade higher, but the difference is smaller than the
run-to-run variation, so neither is meaningfully ahead.

The column that is not close is the fourth. `package:image` hands over the finished file, so what it
holds *is* the file; this holds a fixed staging buffer. At 60 frames that is 5.19 MB against 0.06 MB;
at 1000 frames it would be ~100 MB against the same 0.06 MB, because one side scales with the
animation and the other does not.

Reproduce it with [`dart run tool/compare.dart`](tool/compare.dart). It decodes **both** outputs and
checks every pixel against the input before reporting a single timing, and refuses to report at all if
either encoder got the picture wrong.

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

The full comparison, and how it is measured, is in [At a glance](#at-a-glance) above.

### Method

Both benchmarks report the **median of nine trials**, not the best of them. An earlier version took
best-of-N and it flattered this package: at 32 colours it showed `gif_writer` ahead, where the median
puts the two level and `package:image` marginally in front. A minimum measures the luckiest moment the
machine had. The comparison also **interleaves** the two encoders rather than running them in blocks,
so a thermal drift or a background process partway through hits both equally, and it prints the range
so a gap smaller than the noise cannot be read as a result.

### On its own

120 frames of 256×256 at 32 colours, [`tool/benchmark.dart`](tool/benchmark.dart):

| workload | throughput | range | output | sink writes |
| :-- | ---: | ---: | ---: | ---: |
| noise — worst case for LZW | **27.2 Mpx/s** | 26.3 – 28.3 | 5.82 MB | 121 |
| smooth gradient | **135.9 Mpx/s** | 132.9 – 141.6 | 0.30 MB | 121 |

Where it started, before any of the tuning below: 12.4 Mpx/s on noise and 36.6 on the gradient.

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
