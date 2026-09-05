@TestOn('vm')
library;

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../example/save_image.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gif_writer_image_');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<img.Image> convert(List<int> bytes) async {
    final input = File('${directory.path}/input');
    final output = File('${directory.path}/output.gif');
    await input.writeAsBytes(bytes);
    await saveAsGif(input.path, output.path);
    final encoded = await output.readAsBytes();
    final decoded = img.decodeGif(encoded)!;
    expect(decoded.numFrames, 1);
    // A still image must not carry the animation looping extension.
    expect(String.fromCharCodes(encoded), isNot(contains('NETSCAPE2.0')));
    return decoded;
  }

  test('saves an opaque JPEG with no transparent pixels', () async {
    final source = img.Image(width: 8, height: 6)..clear(img.ColorRgb8(255, 0, 0));
    final result = await convert(img.encodeJpg(source, quality: 100));
    expect((result.width, result.height), (8, 6));
    expect(result.getPixel(0, 0).r, closeTo(255, 3));
    expect(result.getPixel(0, 0).g, closeTo(0, 3));
    expect(result.getPixel(0, 0).a, 255);
  });

  test('thresholds PNG alpha at 128 and preserves visible colors', () async {
    final source = img.Image(width: 4, height: 1, numChannels: 4);
    for (var x = 0; x < 4; x++) {
      source.setPixelRgba(x, 0, 0, 255, 0, [0, 127, 128, 255][x]);
    }
    final result = await convert(img.encodePng(source));
    expect([for (var x = 0; x < 4; x++) result.getPixel(x, 0).a], [0, 0, 255, 255]);
    expect(result.getPixel(2, 0).g, 255);
  });

  test('expands indexed PNG pixels rather than treating indices as RGBA', () async {
    final source = img.Image(width: 2, height: 1, numChannels: 4, withPalette: true);
    source.palette!.setRgba(0, 255, 0, 0, 255);
    source.palette!.setRgba(1, 0, 0, 255, 255);
    source.getPixel(0, 0).index = 0;
    source.getPixel(1, 0).index = 1;
    final result = await convert(img.encodePng(source));
    expect(result.getPixel(0, 0).r, 255);
    expect(result.getPixel(1, 0).b, 255);
    expect(result.getPixel(1, 0).a, 255);
  });

  test('expands grayscale PNG to color channels', () async {
    final source = img.Image(width: 2, height: 1, numChannels: 1);
    source.setPixelR(0, 0, 0);
    source.setPixelR(1, 0, 255);
    final result = await convert(img.encodePng(source));
    final white = result.getPixel(1, 0);
    expect([white.r, white.g, white.b, white.a], [255, 255, 255, 255]);
    expect(result.getPixel(0, 0).r, 0);
  });

  test('normalizes 16-bit PNG channels and alpha to bytes', () async {
    final source = img.Image(width: 2, height: 1, numChannels: 4, format: img.Format.uint16);
    source.setPixelRgba(0, 0, 65535, 0, 0, 65535);
    source.setPixelRgba(1, 0, 0, 65535, 0, 0);
    final result = await convert(img.encodePng(source));
    expect(result.getPixel(0, 0).r, 255);
    expect(result.getPixel(0, 0).a, 255);
    expect(result.getPixel(1, 0).a, 0);
  });

  test('honors EXIF rotation without rotating an already oriented JPEG twice', () async {
    final source = img.Image(width: 12, height: 8)..clear(img.ColorRgb8(255, 0, 0));
    source.exif.imageIfd.orientation = 6;
    final result = await convert(img.encodeJpg(source, quality: 100));
    expect((result.width, result.height), (8, 12));
  });

  test('saves just the first decoded animation frame', () async {
    final first = img.Image(width: 2, height: 1, numChannels: 3, withPalette: true);
    first.palette!.setRgb(0, 255, 0, 0);
    first.palette!.setRgb(1, 0, 0, 255);
    final second = img.Image.from(first);
    second.getPixel(0, 0).index = second.getPixel(1, 0).index = 1;
    final encoder = img.GifEncoder()..addFrame(first)..addFrame(second);
    final result = await convert(encoder.finish()!);
    expect(result.getPixel(0, 0).r, 255);
    expect(result.getPixel(0, 0).b, 0);
  });

  test('invalid input neither creates nor truncates a destination', () async {
    final input = File('${directory.path}/invalid');
    final existing = File('${directory.path}/existing.gif');
    final missing = File('${directory.path}/missing.gif');
    await input.writeAsString('not an image');
    await existing.writeAsString('keep this');
    for (final output in [existing, missing]) {
      await expectLater(saveAsGif(input.path, output.path), throwsFormatException);
    }
    expect(await existing.readAsString(), 'keep this');
    expect(await missing.exists(), isFalse);
  });

  test('malformed PNG leaves the destination unchanged', () async {
    final input = File('${directory.path}/truncated.png');
    final output = File('${directory.path}/existing.gif');
    await input.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
    await output.writeAsString('keep this');
    await expectLater(saveAsGif(input.path, output.path), throwsA(anything));
    expect(await output.readAsString(), 'keep this');
  });

  test('destination failure reaches the caller after cleanup', () async {
    final input = File('${directory.path}/input.png');
    await input.writeAsBytes(img.encodePng(img.Image(width: 1, height: 1)));
    await expectLater(
      saveAsGif(input.path, '${directory.path}/missing/output.gif'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
