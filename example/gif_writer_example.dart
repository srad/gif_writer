import 'dart:math';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';

/// Writes a 200-frame animation without ever holding more than one frame.
///
/// At 256x256 that is thirteen megapixels of input; the process never holds more
/// than the 64 kB frame it is working on, because each one is compressed
/// straight into the file.
Future<void> main() async {
  const size = 256;
  const frames = 200;

  // A 32-step blue-to-white ramp. Any table of up to 256 colours will do; this
  // package does not quantise, so what you index is exactly what decodes.
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

  // Reused across every frame. Allocating one per frame would be the easy way to
  // undo the point of the package.
  final pixels = Uint8List(size * size);

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

  await gif.close();
  print('wrote plasma.gif — $frames frames, ${size}x$size');

  await _rgbExample();
}

/// The other entry point: **RGB in**, mapped onto a table you supply.
///
/// Colours the table cannot hold are dithered between the two nearest entries.
/// The default is [GifDither.blueNoise] rather than Floyd–Steinberg, because
/// error diffusion makes static regions decode differently from frame to frame —
/// see the README.
Future<void> _rgbExample() async {
  const size = 128;

  // The 216-colour web-safe cube: six levels per channel.
  final colors = GifColorTable.packed(<int>[
    for (var r = 0; r < 6; r++)
      for (var g = 0; g < 6; g++)
        for (var b = 0; b < 6; b++)
          (r * 51) << 16 | (g * 51) << 8 | (b * 51),
  ]);

  final gif = GifWriter.toFile(
    'gradient.gif',
    width: size,
    height: size,
    colors: colors,
    dither: GifDither.blueNoise,
  );

  final rgb = Uint8List(size * size * 3);
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

  await gif.close();
  print('wrote gradient.gif — 60 RGB frames dithered onto 216 colours');
}
