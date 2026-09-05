import 'dart:io';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;

/// Saves the first decoded frame. Existing destinations are overwritten.
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

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('Usage: dart run example/save_image.dart input.png output.gif');
    exitCode = 64;
    return;
  }
  await saveAsGif(args[0], args[1]);
}
