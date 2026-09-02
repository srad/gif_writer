# gif_writer

A streaming GIF encoder for Dart. Frames are compressed and written to a sink as they arrive, so
memory stays flat however long the animation runs.

Every other GIF encoder available in Dart builds the finished file in memory and hands it over at the
end. That is fine for a six-frame spinner and unworkable for a long capture on a phone: a thousand
512×512 frames is a hundred megabytes of `Uint8List` before a single byte reaches the disk.

Nothing in the format requires it. A GIF is a header, a colour table, then self-contained per-frame
blocks, then a one-byte trailer — no frame count in the header, no index, nothing to backpatch. This
package writes it that way.

```dart
import 'package:gif_writer/gif_writer.dart';

final gif = GifWriter.toFile(
  'out.gif',
  width: 64,
  height: 64,
  colors: GifColorTable.packed(<int>[0x000000, 0xFFFFFF]),
);

for (final frame in frames) {
  await gif.addIndexedFrame(frame, delay: const Duration(milliseconds: 50));
}
await gif.close();
```

## Any sink, not just files

The core imports no `dart:io`, so it runs on the web too. `GifWriter` takes any
`StreamSink<List<int>>`:

```dart
final gif = GifWriter(socket, width: w, height: h, colors: colors);
```

It is also a `StreamConsumer<GifFrame>`, so a stream of frames pipes straight in and is consumed as it
is produced:

```dart
await frames.pipe(GifWriter.toFile('out.gif', width: w, height: h, colors: colors));
```

## Back-pressure

`addIndexedFrame` awaits the sink once per frame. Without that the buffering would simply move one
layer down — a producer faster than the disk would queue frames inside the sink, using the same memory
somewhere harder to notice. `GifWriter.toFile` wires this to `IOSink.flush`; pass `onFlush` yourself
for other sinks.

## What it does not do yet

**0.1.0 takes indexed frames only**: you supply the colour table and one byte per pixel. That is the
whole of what the format needs, and it is exact — no quantiser in the path, so what you put in is what
decodes out, byte for byte.

Coming next:

| | |
| --- | --- |
| 0.2.0 | Octree quantisation and RGBA input, per-frame or global palettes |
| 0.3.0 | Dithering, transparency, disposal methods |
| 0.4.0 | Frame diffing — write only the changed rectangle |

Quantisation is deliberately not first. It is the part with a memory cost of its own, and getting the
streaming container right matters more than getting more input formats early.

## Delays are hundredths of a second

That is all GIF stores. A `Duration` is rounded to the nearest hundredth, and **most viewers refuse
delays below two hundredths**, substituting ten. A 60 fps GIF is not a thing the format can express;
this package writes what you ask for rather than pretending otherwise.

## Testing

Round trips are verified against [`package:image`](https://pub.dev/packages/image) — a separate
implementation, deliberately, because checking an encoder against its own decoder proves only that the
two share a misunderstanding.

The streaming guarantee has its own tests, and they are checked by tampering: make the writer
accumulate, and they must fail. A guard never seen red is not known to guard anything.

## Licence

MIT. See [LICENSE](LICENSE).
