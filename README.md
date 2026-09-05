<h1 align="center">gif_writer</h1>

<p align="center">
  <strong>A fast, low-memory GIF encoder for Dart.</strong><br>
  Stream frames to a file or sink. Await each frame to keep memory bounded.
</p>

<p align="center">
  <a href="https://pub.dev/packages/gif_writer"><img src="https://img.shields.io/pub/v/gif_writer.svg?logo=dart&logoColor=white" alt="pub package"></a>
  <a href="https://github.com/srad/gif_writer/blob/v0.5.0/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT licence"></a>
  <img src="https://img.shields.io/badge/SDK-%E2%89%A5%203.7-0175C2?logo=dart&logoColor=white" alt="Dart SDK 3.7+">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="no runtime dependencies">
</p>

- Indexed, RGB, and RGBA input.
- Automatic palette generation, six dithering options, and binary transparency.
- Files on native platforms; custom sinks on native platforms and the web.
- No runtime dependencies.

## Install

```console
dart pub add gif_writer
```

## Quick start

Pass RGB pixels and let the writer derive a palette from the first frame:

```dart
import 'package:gif_writer/gif_writer.dart';

final gif = GifWriter.toFile('out.gif', width: 256, height: 256);
try {
  for (final rgb in frames) {
    await gif.addRgbFrame(
      rgb, // Uint8List: 256 × 256 × 3 bytes, in RGB order
      delay: const Duration(milliseconds: 50),
    );
  }
} finally {
  await gif.close();
}
```

The first frame's palette is reused for the whole animation. To supply your own,
pass `colors: GifColorTable.packed([0x000000, 0xFF5500, 0xFFFFFF])`.

See the [runnable examples](https://github.com/srad/gif_writer/blob/v0.5.0/example/gif_writer_example.dart) for indexed frames,
RGB, palette generation, and transparency.

## Save an image as GIF

For PNG, JPEG, or another format supported by `image`, add the decoder with
`dart pub add image`. This native-file example saves one decoded frame and handles
binary transparency; it does not preserve an input animation.

```dart
import 'dart:io';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;

Future<void> saveAsGif(String inputPath, String outputPath) async {
  var source = img.decodeImage(await File(inputPath).readAsBytes(), frame: 0);
  if (source == null) throw FormatException('Unsupported image: $inputPath');

  final orientation = source.exif.imageIfd.orientation;
  if (orientation != null && orientation >= 2 && orientation <= 8) {
    source = img.bakeOrientation(source);
  }
  final transparency = source.hasAlpha ? GifTransparency() : null;
  if (source.hasPalette || source.format != img.Format.uint8 ||
      source.numChannels != 4) {
    source = source.convert(format: img.Format.uint8, numChannels: 4);
  }
  final rgba = source.getBytes(order: img.ChannelOrder.rgba);
  final gif = GifWriter.toFile(
    outputPath,
    width: source.width,
    height: source.height,
    repeat: GifRepeat.once,
    transparency: transparency,
  );
  try {
    await gif.addRgbaFrame(rgba);
  } finally {
    await gif.close();
  }
}

Future<void> main() => saveAsGif('input.png', 'output.gif');
```

The source is decoded in memory before writing. GIF palette conversion can change
colours, and alpha below 128 becomes transparent. The encoder itself has no runtime
dependencies. [Run this example](https://github.com/srad/gif_writer/blob/v0.5.0/example/save_image.dart).

## Input and options

| Input | Method |
| :-- | :-- |
| Palette indices, 1 byte per pixel | `await gif.addIndexedFrame(indices)` |
| RGB, 3 bytes per pixel | `await gif.addRgbFrame(rgb)` |
| RGBA, 4 bytes per pixel | `await gif.addRgbaFrame(rgba, background: 0xFFFFFF)` |

All methods accept `delay:`. Indexed frames require an established palette and
preserve its colours exactly. Delays are rounded to hundredths of a second.

| Constructor option | Default and alternatives |
| :-- | :-- |
| `colors:` | Derived from the first RGB/RGBA frame; supply a `GifColorTable` to reuse a palette. |
| `quantizer:` | `GifQuantizer.octree`; `wu` is also available. |
| `dither:` | `GifDither.blueNoise`; also `none`, `bayer4`, `bayer8`, `floydSteinberg`, and `atkinson`. |
| `repeat:` | `GifRepeat.forever`; use `once` or `times(n)`. |
| `transparency:` | Off; pass `GifTransparency()` for binary alpha. |

With transparency enabled, RGBA pixels below `alphaThreshold` (default 128) become
transparent and `background:` is optional. A supplied palette must have at most
255 colours to leave a transparent slot. Use `gif.transparentIndex` for indexed
transparency and `GifTransparency(disposal: …)` to control frame disposal.

## Streams and custom sinks

Consume a `Stream<GifFrame>` with `await gif.addStream(frames)`, then close the
writer in a `finally` block as above. Construct frames with `GifFrame(indices: …)`,
`GifFrame.rgb(…)`, or `GifFrame.rgba(…)`.

For a socket or a web-compatible sink, use `GifWriter(sink, width: …, height: …)`.
Pass `onFlush:` to await your sink's drain operation; `toFile` wires this up
automatically. A sink that collects the whole output still uses memory for that
output. `toFile` is unavailable on the web.

**Await each frame and keep its input buffer unchanged until its future completes.**
Overlapping calls run in order, but queued buffers consume memory: four waiting
4K RGBA frames retain about **126.6 MiB**. While `addStream` is active, wait for it
to finish before adding frames or closing the writer.

`close()` drains accepted frames and closes the sink; repeated calls share the
same completion. Invalid input rejects that frame; sink failures stop further
writes and surface through frame operations or `close()`. Always close after an
error to release the sink.

## Performance

The latest comparison against [`image` 4.9.2](https://pub.dev/packages/image/versions/4.9.2)
measured **1.53–2.28× the throughput** and **0.8–6.4% smaller output** across four
indexed workloads. Windows x64, Dart 3.13.2, September 2026; AOT, 60 frames of
256×256, supplied palettes, median of nine interleaved trials.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/srad/gif_writer/v0.5.0/doc/throughput-dark.png">
    <img src="https://raw.githubusercontent.com/srad/gif_writer/v0.5.0/doc/throughput-light.png" alt="Indexed throughput: gif_writer 48.6–91.9 Mpx/s versus image 26.7–47.7 Mpx/s; output 0.8–6.4% smaller" width="100%">
  </picture>
</p>

Awaited indexed streaming retained approximately **0.31–0.32 MiB** at both 60 and
1,000 frames. Across the same workloads, `image` retained **1.92–5.77 MiB** and
**51.70–155.65 MiB**, respectively. These separate JIT measurements count live
memory after garbage collection, exclude shared inputs, and are not peak memory.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/srad/gif_writer/v0.5.0/doc/memory-dark.png">
    <img src="https://raw.githubusercontent.com/srad/gif_writer/v0.5.0/doc/memory-light.png" alt="Measured retained memory at 60 and 1,000 frames across four workloads; gif_writer stays near 0.32 MiB" width="100%">
  </picture>
</p>

Results depend on workload and hardware; RGB/RGBA mapping and palette generation
have additional costs. See [measurements and methodology](https://github.com/srad/gif_writer/blob/v0.5.0/doc/encoding-review.md)
for ranges, standalone and dither benchmarks, and reproduction commands.

## Status

Version **0.5.0** includes ordered writes and correctness fixes.
Frame diffing and per-frame palettes remain future work; see the
[roadmap](https://github.com/srad/gif_writer/blob/v0.5.0/ROADMAP.md).

The current implementation passes **182 VM tests and 168 Chrome tests**, with
clean static analysis. Coverage includes independent decoding, strict LZW
termination checks, transparency, queued writes, and failure cleanup. Fourteen
file-system and image-conversion tests run only on the VM.

## Licence

MIT © [Saman Sedighi Rad](https://github.com/srad) — see [LICENSE](https://github.com/srad/gif_writer/blob/v0.5.0/LICENSE).
