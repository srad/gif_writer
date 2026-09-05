@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() async { directory = await Directory.systemTemp.createTemp('gif_writer_'); });
  tearDown(() async { await directory.delete(recursive: true); });

  for (final scenario in ['width', 'height', 'palette']) {
    test('invalid $scenario neither truncates nor creates a file', () async {
      final existing = File('${directory.path}/existing.gif');
      final missing = File('${directory.path}/missing.gif');
      await existing.writeAsString('keep this content');
      for (final file in [existing, missing]) {
        expect(() => GifWriter.toFile(file.path,
          width: scenario == 'width' ? 0 : 1,
          height: scenario == 'height' ? 65536 : 1,
          colors: scenario == 'palette'
              ? GifColorTable.packed(List<int>.filled(256, 0)) : null,
          transparency: scenario == 'palette' ? GifTransparency() : null,
        ), throwsArgumentError);
      }
      await Future<void>.delayed(Duration.zero);
      expect(await existing.readAsString(), 'keep this content');
      expect(await missing.exists(), isFalse);
    });
  }

  test('real file sink accepts overlapping writes and close', () async {
    final file = File('${directory.path}/queued.gif');
    final gif = GifWriter.toFile(file.path, width: 2, height: 1,
      colors: GifColorTable.packed([0, 0xFFFFFF]));
    final frames = [for (var i = 0; i < 20; i++)
      gif.addIndexedFrame(Uint8List.fromList([i % 2, (i + 1) % 2]))];
    final closing = gif.close();
    await Future.wait(frames);
    await closing;
    final decoded = img.GifDecoder().decode(await file.readAsBytes())!;
    expect(decoded.frames.length, 20);
    for (var i = 0; i < 20; i++) {
      expect(decoded.frames[i].getPixel(0, 0).r, i.isEven ? 0 : 255);
    }
  });
}
