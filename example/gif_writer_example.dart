import 'dart:math';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';

/// Writes four animations using indexed, RGB, derived-palette, and RGBA input.
///
/// Each example awaits its writes and reuses one input buffer. The encoder's
/// reusable buffers are additional; memory stays bounded as frames are added.
Future<void> main() async {
  const size = 256;
  const frames = 200;

  // A 32-step blue-to-white ramp. An indexed frame is byte-exact: what you index
  // is exactly what decodes, with nothing quantised or approximated.
  final colors = GifColorTable.packed(<int>[
    for (var i = 0; i < 32; i++)
      (i * 255 ~/ 31) << 16 | (i * 255 ~/ 31) << 8 | 0xFF,
  ]);

  final gif = GifWriter.toFile(
    'plasma.gif',
    width: size,
    height: size,
    colors: colors,
  );

  // Reuse this buffer only after the previous frame's future completes.
  final pixels = Uint8List(size * size);

  try {
    for (var f = 0; f < frames; f++) {
      final phase = f * 2 * pi / frames;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final value =
              sin(x / 16 + phase) + sin(y / 24) + sin((x + y) / 32 + phase);
          pixels[y * size + x] = (((value + 3) / 6) * 31).round().clamp(0, 31);
        }
      }
      await gif.addIndexedFrame(pixels, delay: const Duration(milliseconds: 50));
    }
  } finally {
    await gif.close();
  }
  print('wrote plasma.gif — $frames frames, ${size}x$size');

  await _rgbExample();
}

/// The other entry point: **RGB in**, mapped onto a table you supply.
///
/// Colours the table cannot hold are dithered between the two nearest entries.
/// The default is [GifDither.blueNoise] rather than Floyd–Steinberg, because
/// error diffusion makes static regions decode differently from frame to frame —
/// see the dither tradeoffs in doc/encoding-review.md.
Future<void> _rgbExample() async {
  const size = 128;

  // The 216-colour web-safe cube: six levels per channel.
  final colors = GifColorTable.packed(<int>[
    for (var r = 0; r < 6; r++)
      for (var g = 0; g < 6; g++)
        for (var b = 0; b < 6; b++) (r * 51) << 16 | (g * 51) << 8 | (b * 51),
  ]);

  final gif = GifWriter.toFile(
    'gradient.gif',
    width: size,
    height: size,
    colors: colors,
    dither: GifDither.blueNoise,
  );

  final rgb = Uint8List(size * size * 3);
  try {
    for (var f = 0; f < 60; f++) {
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final p = (y * size + x) * 3;
          // A smooth gradient — exactly what a small palette cannot represent and
          // what a dither is for.
          rgb[p] = (x * 255 ~/ size);
          rgb[p + 1] = (y * 255 ~/ size);
          rgb[p + 2] = ((f * 255 ~/ 60) + x) & 0xFF;
        }
      }
      await gif.addRgbFrame(rgb, delay: const Duration(milliseconds: 40));
    }
  } finally {
    await gif.close();
  }
  print('wrote gradient.gif — 60 RGB frames dithered onto 216 colours');

  await _quantisedExample();
}

/// The third way in: **RGB with no palette at all**.
///
/// Leave `colors:` unset and the writer derives a global table from the first
/// frame — the answer to "I have a photo, not a palette." [GifQuantizer.octree]
/// is the default (its memory is bounded by the palette); [GifQuantizer.wu] costs
/// a transient histogram for a little more fidelity. `tool/quantize.dart` measures
/// the difference.
Future<void> _quantisedExample() async {
  const size = 128;

  final gif = GifWriter.toFile(
    'quantised.gif',
    width: size,
    height: size,
    // No colours supplied — they are chosen from the pixels below.
    quantizer: GifQuantizer.wu,
  );

  final rgb = Uint8List(size * size * 3);
  try {
    for (var f = 0; f < 40; f++) {
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final p = (y * size + x) * 3;
          // A drifting wash of many more colours than 256 — the case that needs a
          // palette chosen for it.
          rgb[p] = (x * 255 ~/ size);
          rgb[p + 1] = (y * 255 ~/ size);
          rgb[p + 2] = ((f * 6) + (x ~/ 2) + (y ~/ 2)) & 0xFF;
        }
      }
      await gif.addRgbFrame(rgb, delay: const Duration(milliseconds: 50));
    }
  } finally {
    await gif.close();
  }
  print(
    'wrote quantised.gif — 40 RGB frames onto a palette derived from the first',
  );

  await _transparentExample();
}

/// The fourth way in: **RGBA with real transparency**.
///
/// Turn on [GifTransparency] and `background` becomes optional — alpha below the
/// threshold punches a hole instead of compositing onto a colour. A disc of
/// colour orbits a fully transparent field; open the file over a coloured page
/// and the background shows through everywhere but the disc.
Future<void> _transparentExample() async {
  const size = 128;
  const frames = 60;

  final gif = GifWriter.toFile(
    'transparent.gif',
    width: size,
    height: size,
    // No colours supplied — the palette is derived from the disc's opaque
    // pixels, with one slot held back for the transparent index.
    transparency: GifTransparency(),
  );

  final rgba = Uint8List(size * size * 4);
  try {
    for (var f = 0; f < frames; f++) {
      final phase = f * 2 * pi / frames;
      final cx = size / 2 + cos(phase) * size / 4;
      final cy = size / 2 + sin(phase) * size / 4;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final p = (y * size + x) * 4;
          final inside = (x - cx) * (x - cx) + (y - cy) * (y - cy) < 24 * 24;
          rgba[p] = (x * 255 ~/ size);
          rgba[p + 1] = (y * 255 ~/ size);
          rgba[p + 2] = 0xC0;
          // Opaque inside the disc, a hole everywhere else.
          rgba[p + 3] = inside ? 255 : 0;
        }
      }
      await gif.addRgbaFrame(rgba, delay: const Duration(milliseconds: 40));
    }
  } finally {
    await gif.close();
  }
  print(
    'wrote transparent.gif — $frames frames, a disc over a transparent field',
  );
}
