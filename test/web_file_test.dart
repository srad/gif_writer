@TestOn('browser')
library;

import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

void main() {
  test('toFile reports the unsupported browser file API', () {
    expect(
      () => GifWriter.toFile('unused.gif', width: 1, height: 1),
      throwsUnsupportedError,
    );
  });
}
