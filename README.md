<h1 align="center">gif_writer</h1>

<p align="center">
  <strong>A high-performance, low-memory GIF encoder for Dart.</strong><br>
  Frames are compressed and written out as they arrive, so memory stays flat<br>
  however long the animation runs — while running <strong>1.5–1.9× faster</strong> than the<br>
  alternative and writing a smaller file.
</p>

<p align="center">
  <a href="https://pub.dev/packages/gif_writer"><img src="https://img.shields.io/pub/v/gif_writer.svg?logo=dart&logoColor=white" alt="pub package"></a>
  <a href="https://pub.dev/packages/gif_writer/score"><img src="https://img.shields.io/pub/points/gif_writer?logo=dart&logoColor=white" alt="pub points"></a>
  <a href="https://pub.dev/packages/gif_writer/score"><img src="https://img.shields.io/pub/likes/gif_writer?logo=dart&logoColor=white" alt="likes"></a>
  <a href="https://github.com/srad/gif_writer/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT licence"></a>
  <img src="https://img.shields.io/badge/SDK-%E2%89%A5%203.7-0175C2?logo=dart&logoColor=white" alt="Dart SDK 3.7+">
  <img src="https://img.shields.io/badge/platforms-all-success" alt="all platforms">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="no dependencies">
</p>

---

## At a glance

Against [`package:image`](https://pub.dev/packages/image), the only other GIF encoder for Dart.
60 frames of 256×256, both given pre-palettised input so neither quantises. **Median of nine
interleaved trials**, and every gap below is wider than the run-to-run spread of either encoder:

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/srad/gif_writer/main/doc/throughput-dark.png">
    <img src="https://raw.githubusercontent.com/srad/gif_writer/main/doc/throughput-light.png" alt="Throughput and output size against package:image across four workloads" width="100%">
  </picture>
</p>

| workload | gif_writer | `package:image` | | gif_writer | `package:image` | |
| :-- | --: | --: | :-- | --: | --: | :-- |
| photo · 32 colours | **95.1 Mpx/s** | 48.3 Mpx/s | **+97%** | **1.13 MB** | 1.21 MB | **−6.4%** |
| photo · 256 colours | **58.8 Mpx/s** | 35.9 Mpx/s | **+64%** | **3.34 MB** | 3.39 MB | **−1.3%** |
| noise · 32 colours | **68.4 Mpx/s** | 28.2 Mpx/s | **+143%** | **2.91 MB** | 3.04 MB | **−4.3%** |
| noise · 256 colours | **52.1 Mpx/s** | 31.0 Mpx/s | **+68%** | **5.15 MB** | 5.19 MB | **−0.8%** |
| | *throughput* | | | *file written* | | |

**1.6–2.4× faster, and the file is smaller every time.** Speed alone would not settle it — an encoder
can always go faster by compressing worse — so the output size sits in the table beside it.

The percentages are from one run on one machine, and they move: a second run of the same tool put
noise · 32 at +147% and photo · 256 at +66%. What is stable across runs is the direction, the rough
size of the gap, and the file sizes, which are **byte-identical every time** because compression is
deterministic. Treat the throughput column as "comfortably faster", not as four significant figures —
and run it on your own hardware, which is the only number that describes your hardware.

And the number that is not a percentage:

| | held in memory, 60 frames | held in memory, 1000 frames |
| :-- | --: | --: |
| **gif_writer** | **0.31 MB** | **0.31 MB** |
| `package:image` | 5.19 MB | ~87 MB |

That 0.31 MB is the whole fixed overhead of the indexed path — a 64 kB staging
buffer plus the 256 kB LZW string table — and it is the same number as
[Where the speed comes from](#where-the-speed-comes-from) below. Neither column
counts the caller's own frame buffer, which both encoders need.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/srad/gif_writer/main/doc/memory-dark.png">
    <img src="https://raw.githubusercontent.com/srad/gif_writer/main/doc/memory-light.png" alt="Memory held against frames written: flat for gif_writer, linear for package:image" width="88%">
  </picture>
</p>

`package:image` hands over the finished file, so what it holds *is* the file. This holds a fixed
staging buffer. One side scales with the animation; the other does not — and that is the whole reason
this package exists.

Reproduce the numbers by building [`tool/compare.dart`](tool/compare.dart) with `dart compile exe`
and running that — AOT, because the JIT's numbers wander (see *A note on measuring this yourself*,
below). It decodes **both** outputs and checks every pixel against the input before reporting a single
timing, and refuses to report at all if either encoder got the picture wrong. Redraw the charts with
[`python tool/charts.py`](tool/charts.py).

## The problem

Every GIF encoder available for Dart builds the finished file in memory and hands it back at the end.
That is fine for a six-frame spinner. It is unworkable for anything long:

A thousand 256×256 frames is ~87 MB held at once — [measured](#at-a-glance), not estimated — and that
scales with the frame size, so the same recording at 512×512 is four times worse. On a phone, which is
where long GIFs actually get made, that is the difference between working and being killed.

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

`frame` is one byte per pixel — an index into the colour table you supplied. Nothing approximates it:
what you put in is what decodes out, **byte for byte**.

Already holding ordinary pixels? Pass those instead and they are mapped onto the same table, dithered
where it cannot hold the exact colour:

```dart
await gif.addRgbFrame(rgb);                          // 3 bytes per pixel
await gif.addRgbaFrame(rgba, background: 0xFFFFFF);  // 4, composited first
```

A pixel that *is* exactly a table colour still maps to that entry, so palettised content survives this
path unchanged.

No palette at all? Leave `colors:` unset and the writer chooses one, quantising the first frame:

```dart
final gif = GifWriter.toFile('out.gif', width: w, height: h);  // no colors:
await gif.addRgbFrame(rgb);   // the first frame's pixels derive the global table
```

Or derive one yourself from a representative image and reuse it, picking the algorithm:

```dart
final colors = GifColorTable.quantize(rgb, quantizer: GifQuantizer.wu);
```

`GifQuantizer.octree` is the default — its memory is bounded by the palette, never the image;
`GifQuantizer.wu` scores a little higher on fidelity for a transient histogram. See [Scope](#scope).

## Recipes

<details open>
<summary><strong>Pipe a stream of frames</strong></summary>

`GifWriter` is a `StreamConsumer<GifFrame>`, so frames are consumed as they are produced and never
collected into a list. A `GifFrame` comes in the same three shapes as the `add…Frame` methods.

```dart
await frames.pipe(
  GifWriter.toFile('out.gif', width: w, height: h, colors: colors),
);

// frames yields any mix of:
GifFrame(indices: bytes);                      // one byte per pixel
GifFrame.rgb(rgb);                             // three
GifFrame.rgba(rgba, background: 0xFFFFFF);     // four
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

// A socket can fail out of band — the peer resets and the failure arrives
// through the sink's `done`, not the `add` that provoked it. Await `gif.done`
// alongside your writes to see it; `gif.close()` awaits it for you at the end.
await gif.done;
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
<summary><strong>Transparency</strong></summary>

GIF transparency is **binary** — a pixel is fully opaque or fully absent; the format has no partial
alpha. Turn it on with `transparency:` and one palette slot is reserved as the transparent index. Then
`addRgbaFrame`'s `background` becomes optional: alpha below the threshold punches a hole instead of
compositing onto a colour.

```dart
final gif = GifWriter.toFile(
  'out.gif',
  width: w,
  height: h,
  // No colours supplied — the palette is derived from the opaque pixels, with
  // one slot held back. Supply `colors:` instead and it must leave a slot free
  // (at most 255 entries).
  transparency: GifTransparency(
    alphaThreshold: 128,                       // alpha < 128 is a hole
    disposal: GifDisposal.restoreBackground,   // a hole reveals the page
  ),
);

await gif.addRgbaFrame(rgba);                  // no background needed
await gif.close();
```

Because the format thresholds rather than blends, a `background` — when you do pass one — only refines
the colour of a pixel that is actually drawn. An `addIndexedFrame` caller can place holes by hand using
`gif.transparentIndex`.
</details>

<details>
<summary><strong>Trim the memory further</strong></summary>

```dart
GifWriter(sink, ..., bufferSize: 4 * 1024);
```

The staging buffer is the package's whole fixed overhead besides the LZW tables. Below about a
kilobyte the syscalls cost more than the buffer saves.

If you only ever call `addIndexedFrame`, that is the whole story — the 96 kB colour cube and the
dither's error rows are allocated on the **first RGB frame** and never before it.
</details>

## Benchmarks

### Against `package:image`

60 frames of 256×256, from [`tool/compare.dart`](tool/compare.dart) built with `dart compile exe`
(AOT). Both encoders are given
frames that **already carry a palette**, so neither quantises — otherwise `image` would be paying for
NeuQuant this package does not implement, and the comparison would say nothing. The tool decodes both
outputs and checks them pixel-for-pixel against the input before printing a single number; it refuses
to report timings if either is wrong.

The full comparison, and how it is measured, is in [At a glance](#at-a-glance) above.

### Method

Both benchmarks report the **median of nine trials**, not the best of them. An earlier version took
best-of-N, and it flattered this package: at 32 colours it showed `gif_writer` clearly ahead where the
median put the two level, which is what sent us looking and turned up the broken hash above. A minimum
measures the luckiest moment the machine had; the median is what a caller sees.

The comparison **interleaves** the two encoders rather than running them in blocks, so a thermal drift
or a background process partway through hits both equally. It prints the range beside every median, and
says in words when a gap is inside the spread, so a difference too small to be real cannot be read as a
result. And it **decodes both outputs and checks every pixel** before reporting any timing at all —
`package:image` silently quantises a frame that arrives without a palette, and a comparison against an
encoder doing extra work would be worthless.

### On its own

120 frames of 256×256 at 32 colours, [`tool/benchmark.dart`](tool/benchmark.dart) built with
`dart compile exe` (AOT):

| workload | throughput | range | output | sink writes |
| :-- | ---: | ---: | ---: | ---: |
| noise — worst case for LZW | **64.4 Mpx/s** | 50.3 – 67.2 | 5.82 MB | 121 |
| photo — representative content | **94.1 Mpx/s** | 81.3 – 96.8 | 2.26 MB | 121 |
| smooth gradient — best case | **156.3 Mpx/s** | 150.3 – 166.7 | 0.30 MB | 121 |

Where it started, before any of the tuning below: 12.4 Mpx/s on noise and 36.6 on the gradient.

**The test images are generated, not bundled.** The convention in this field is to reach for
"Lenna", which IEEE retired in 2024 and most venues have dropped over its provenance — and shipping
any photograph would add weight to the package and a licence to reason about. What an LZW encoder
actually responds to is the *statistics* of the content: run lengths, and how often the dictionary
hits. So [`tool/sample_image.dart`](tool/sample_image.dart) generates the three cases that bracket
real content — uniform noise, a gradient, and a photographic image built from smooth shading, hard
edges and fine grain. Reproducible exactly, on any machine, with no download.

### Where the speed comes from

Fixed overhead does not grow with the animation. What it is depends on which entry point you use, and
**an indexed-only caller pays nothing for the RGB machinery** — none of it is allocated until the
first RGB frame:

| path | fixed overhead |
| :-- | --: |
| `addIndexedFrame` | **~320 kB** — a 64 kB staging buffer plus a 256 kB LZW string table |
| `addRgbFrame`, ordered dither | ~416 kB — plus the 96 kB inverse colour cube |
| `addRgbFrame`, error diffusion | ~416 kB + `12 × width` for two rows of error |

All of it allocated **once for the whole animation** rather than per frame.

| | |
| --- | --- |
| **Open-addressed `Int32List` string table** | not a `Map<int, int>`. Probed once per pixel, the hottest loop here. |
| **A hash every key can address** | the classic `(pixel << 4) ^ prefix` from the C implementations is quietly broken below 256 colours: at 32 it never exceeds 4095, so most of the table is unreachable and the load factor is 1.0. Mixing the key properly took noise from 27.2 to 59.7 Mpx/s. |
| **A power-of-two table with an odd step** | odd is coprime to a power of two, so the probe still reaches every slot — what a prime table buys, without a division per pixel. The prime it replaced measured 86.8 Mpx/s on a gradient against 142.9. |
| **Sized at a 0.125 load factor** | the classic 5003 slots puts 4096 codes at 0.82 and probes several times per pixel. Measured AOT and interleaved across four powers of two, 32768 takes both noise (64.4 Mpx/s against 16384's 59.5) and photo, while 65536 gives the noise win back to cache pressure. 32768 looked like a wash the last time it was tried — but only because every reset then zeroed the table, and the row below made clearing nearly free; once it is, the bigger table wins. It costs 256 kB against 16384's 128 kB, which is why held memory is now 0.31 MB rather than 0.19. |
| **A string table retired, not cleared** | the dictionary resets far more often than once per frame — measured at 256×256, ten times a frame on noise at 32 colours and seventeen at 256 — and each reset used to zero 64 kB. Slots now carry a generation counter, so a reset is an increment and the table is genuinely cleared only every 1023 generations. Interleaved against 0.2.0, AOT: **+47% noise, +26% photo, +24% gradient**. Encoded bytes unchanged. |
| **Batched sink writes** | passing every 255-byte sub-block straight through cost **24,365** sink calls for a 5.8 MB animation. Batching makes it 121. |
| **Sub-blocks written in place** | the length byte is reserved and patched afterwards, so compressed bytes are never staged in a scratch array and copied — that copy is a `memcpy` of the entire output. |
| **No per-pixel range check at 256 colours** | where no byte *can* be out of range. Elsewhere the check ORs the bytes together and only walks precisely if that suggests trouble — 2.6% rather than a second pass. |

Two changes that looked obviously right and measured worse, kept here so nobody repeats them: a
power-of-two hash with **linear** probing ran **36× slower**, because GIF keys cluster hard and linear
probing turns clustering into long walks; and a prime table with `key % size`, which is correct and
was the implementation for a while, pays a division on every pixel — most painfully where runs are
long and the first probe already succeeds.

There was a third — that enlarging the hash past 16384 cost more in clearing between frames than it
saved in probing. That was true when it was measured and is not any more: the table is no longer
cleared between frames, so the finding died with the cost that caused it — and the table is now
32768, the size that dead cost had been hiding.

**A note on measuring this yourself.** Under the JIT these workloads swung ±13% run to run on
identical code, wide enough to hide a real 25% change — so a before-and-after pair of `dart run`
timings will not settle anything. Compare with `dart compile exe`, alternating the two builds, which
is both stable and how a Flutter release build actually runs this package. The headline tables above
are AOT medians, and the hash sizing was re-measured that way for this release. The remaining
before/after figures in *Where the speed comes from* — the broken-hash and prime-table comparisons —
are the original JIT experiments against variants no longer in the code, so a gradient reading
156 Mpx/s up top and 142.9 in those notes is JIT-versus-AOT, not a contradiction.

## API

| | |
| --- | --- |
| `GifWriter(sink, …)` | Writes to any `StreamSink<List<int>>`. |
| `GifWriter.toFile(path, …)` | Convenience for `dart:io`, with back-pressure wired to `IOSink.flush`. |
| `addIndexedFrame(indices, delay:)` | One byte per pixel. Validated, then compressed straight out. |
| `addRgbFrame(rgb, delay:)` | Three bytes per pixel, mapped onto your table with the writer's dither. |
| `addRgbaFrame(rgba, background:, delay:)` | Four bytes per pixel. Composited over `background`, or, with `transparency:` on, alpha punches holes and `background` is optional. |
| `GifTransparency(alphaThreshold:, disposal:)` | Turns on binary transparency; reserves a palette slot for the transparent index. |
| `GifDither.blueNoise` / `.bayer4` / `.bayer8` / `.floydSteinberg` / `.atkinson` / `.none` | How in-between colours are resolved. |
| `GifFrame.rgb(…)` / `.rgba(…, background:)` | The same three shapes, for the stream form. |
| `addStream(stream)` / `pipe` | Consume a `Stream<GifFrame>`. |
| `close()` | Writes the trailer and closes the sink; also surfaces an error the sink reported through `done`. |
| `done` | Completes when the sink is done — how an out-of-band sink error (a dropped socket) reaches a streaming caller. |
| `GifColorTable.packed([0xRRGGBB, …])` | Up to 256 colours. |
| `GifColorTable.rgb([r, g, b, …])` | The same, as raw bytes. |
| `GifRepeat.forever` / `.once` / `.times(n)` | Looping. |

### Back-pressure matters

`addIndexedFrame` awaits the sink once per frame. Without that the buffering would simply move one
layer down — a producer faster than the disk would queue frames *inside* the sink, using the same
memory somewhere much harder to notice. `GifWriter.toFile` handles this for you; pass `onFlush`
yourself for other sinks.

### Dithering, and why the default is not Floyd–Steinberg

Pass RGB and the writer maps it onto your table, dithering colours the table cannot hold:

```dart
final gif = GifWriter.toFile(
  'out.gif',
  width: w,
  height: h,
  colors: colors,
  dither: GifDither.blueNoise,   // the default
);
await gif.addRgbFrame(rgb);                            // 3 bytes per pixel
await gif.addRgbaFrame(rgba, background: 0xFFFFFF);    // 4, composited first
```

**Floyd–Steinberg makes the best-looking single image and is the wrong default for an animation.** It
carries error from each pixel into the next, so one pixel changing by one level changes every pixel
after it. Three consequences: static regions decode differently frame to frame and the result
shimmers; the noise defeats the LZW dictionary this package is built around; and no region is ever
byte-identical, which rules out frame diffing.

An ordered dither reads its threshold from position alone. The same colour in the same place always
resolves the same way, so **a one-pixel change affects exactly one pixel** — a property with a test on
it, not just a claim.

Measured with [`tool/dither.dart`](tool/dither.dart), 27 colours on a photographic frame:

| | blurred error | structure | output | rate |
| :-- | --: | --: | --: | --: |
| `none` | 33.37 | 1226 | **0.15 MB** | **65.5 Mpx/s** |
| `bayer4` | 21.10 | 571 | 0.27 MB | 32.7 Mpx/s |
| `bayer8` | 21.09 | 564 | 0.28 MB | 30.9 Mpx/s |
| **`blueNoise`** (default) | **21.05** | 578 | 0.41 MB | 27.6 Mpx/s |
| `floydSteinberg` | **4.04** | 84 | 0.62 MB | 18.4 Mpx/s |
| `atkinson` | 9.72 | 63 | 0.57 MB | 10.2 Mpx/s |

**Read that error column carefully.** It is RMSE after blurring *both* images, because per-pixel error
measures the opposite of what dithering is for — a dithered pixel is deliberately the wrong colour, the
right one on average across its neighbours. On plain per-pixel error `none` scores best of all six and
looks the worst; the tool prints both columns so the divergence is visible rather than hidden.

Blue noise and Bayer score the same there, and that is a limit of the metric rather than a real tie:
blurring destroys high-frequency structure, which is precisely where an ordered dither's artefact
lives. On a flat mid-tone field, where the only structure is the dither's own:

| | structure |
| :-- | --: |
| `bayer4`, `bayer8` | 4095 — the maximum: a pure periodic grid |
| `floydSteinberg` | 4095 — its known "worm" patterns on flat areas |
| `atkinson` | 1870 |
| **`blueNoise`** | **10** |

That 400-fold difference is the whole reason blue noise is the default, and it is visible immediately
on any gradient. **It is not free**: it costs about 50% more bytes than Bayer at 27 colours, because
unstructured noise is harder to compress than a repeating pattern. If output size matters more than
smoothness, `bayer4` is the one to reach for; if the target is a single still image, `floydSteinberg`
is markedly more accurate than anything else here.

### Delays are hundredths of a second

That is all the format stores. A `Duration` is rounded to the nearest hundredth, and **most viewers
refuse delays below two hundredths**, silently substituting ten. A 60 fps GIF is not something GIF can
express; this package writes what you ask for rather than pretending otherwise.

## Scope

**Bring a colour table, or let it derive one.** Indexed frames are byte-exact; RGB frames are mapped
onto the table you supplied, or onto one quantised from the first frame when you supply none.
**Binary transparency** is here as of 0.4.0 (`transparency:`); what is *not* here yet is frame diffing
and per-frame palettes — see 0.4.0.

| version | |
| --- | --- |
| **0.1.0** ✅ | Streaming container, LZW, indexed frames, any sink |
| **0.2.0** ✅ | RGB and RGBA input, mapped to your table, with five dithers |
| **0.2.1** ✅ | Loop-count and dictionary-test fixes; LZW resets without zeroing its table |
| **0.3.0** ✅ | Global palette derivation — octree and Wu quantisers, `colors:` now optional |
| **0.4.0** ✅ | Binary transparency and disposal methods (`transparency:`); `background` now optional |
| 0.5.0 | Frame diffing, per-frame palettes |

The full picture — open work, structural decisions, and what was ruled out and why — is in
[ROADMAP.md](ROADMAP.md).

Quantisation came after the container and the mapping on purpose: it is the part with a memory cost of
its own, and getting the streaming guarantee right mattered more than accepting more input formats
early. It is a **global** palette — one table for the animation, derived from the first frame;
per-frame palettes wait for the local colour tables that 0.4.0's frame diffing brings.

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
