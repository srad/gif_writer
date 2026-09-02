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
}
