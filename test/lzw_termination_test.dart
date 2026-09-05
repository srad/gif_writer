import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

import 'round_trip_test.dart' show RecordingSink;

// A strict decoder, independent of the encoder's hash and insertion code.
// Reading the declared pixel count is insufficient: EOI must also fit entirely
// inside the data sub-blocks, without borrowing bits from their terminator.
({List<int> pixels, Map<int, int> boundaries, int clears}) decodePayload(
  Uint8List payload, int minimum, int expected,
) {
  var bit = 0;
  var width = minimum + 1;
  final clear = 1 << minimum;
  final end = clear + 1;
  var next = end + 1;
  var dictionary = List<List<int>?>.filled(4096, null);
  List<int>? previous;
  final pixels = <int>[];
  final boundaries = <int, int>{};
  var clears = 0;
  while (true) {
    if (bit + width > payload.length * 8) {
      throw const FormatException('truncated LZW code before EOI');
    }
    var code = 0;
    for (var i = 0; i < width; i++, bit++) {
      code |= ((payload[bit ~/ 8] >> (bit % 8)) & 1) << i;
    }
    if (code == clear) {
      clears++;
      width = minimum + 1;
      next = end + 1;
      previous = null;
      dictionary = List<List<int>?>.filled(4096, null);
      continue;
    }
    if (code == end) {
      if (pixels.length != expected) throw const FormatException('wrong pixel count');
      return (pixels: pixels, boundaries: boundaries, clears: clears);
    }
    final List<int> entry;
    if (code < clear) {
      entry = [code];
    } else if (code < next && dictionary[code] != null) {
      entry = dictionary[code]!;
    } else if (code == next && previous != null) {
      entry = [...previous, previous.first];
    } else {
      throw const FormatException('invalid LZW dictionary reference');
    }
    pixels.addAll(entry);
    if (pixels.length > expected) throw const FormatException('excess pixels');
    if (previous != null && next < 4096) {
      dictionary[next++] = [...previous, entry.first];
      if (next == 1 << width && width < 12) {
        width++;
        boundaries.putIfAbsent(width, () => pixels.length);
      }
    }
    previous = entry;
  }
}

(Uint8List, int) imageData(Uint8List gif) {
  var offset = 13 + ((gif[10] & 0x80) == 0 ? 0 : 3 * (1 << ((gif[10] & 7) + 1)));
  while (gif[offset] == 0x21) {
    offset += 2;
    while (gif[offset] != 0) { offset += gif[offset] + 1; }
    offset++;
  }
  expect(gif[offset], 0x2C);
  final flags = gif[offset + 9];
  offset += 10;
  if (flags & 0x80 != 0) offset += 3 * (1 << ((flags & 7) + 1));
  final minimum = gif[offset++];
  final payload = BytesBuilder();
  while (gif[offset] != 0) {
    final length = gif[offset++];
    payload.add(gif.sublist(offset, offset + length));
    offset += length;
  }
  expect(gif[offset + 1], 0x3B);
  return (payload.toBytes(), minimum);
}

Future<Uint8List> encode(Uint8List pixels, int minimum) async {
  final sink = RecordingSink();
  // A two-row image accommodates the long dictionary-reset fixture.
  final height = pixels.length > 65535 ? 2 : 1;
  final gif = GifWriter(sink, width: pixels.length ~/ height, height: height,
    colors: GifColorTable.packed([for (var i = 0; i < 1 << minimum; i++) i * 0x010101]),
    repeat: GifRepeat.once);
  await gif.addIndexedFrame(pixels);
  await gif.close();
  return sink.result;
}

void main() {
  test('strict reader rejects the original truncated end code', () {
    expect(() => decodePayload(Uint8List.fromList([12, 16, 35, 2, 60, 81]), 2, 12),
      throwsFormatException);
  });

  test('12-pixel fixture has a complete five-bit end code', () async {
    final pixels = Uint8List.fromList([1, 0, 0, 1, 3, 2, 2, 0, 2, 0, 3, 1]);
    final (payload, minimum) = imageData(await encode(pixels, 2));
    expect(decodePayload(payload, minimum, pixels.length).pixels, pixels);
  });

  for (var minimum = 2; minimum <= 8; minimum++) {
    test('minimum $minimum: end codes at width boundaries and dictionary resets', () async {
      var state = 12345;
      final pixels = Uint8List(100000);
      for (var i = 0; i < pixels.length; i++) {
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
        pixels[i] = (state >> 16) & ((1 << minimum) - 1);
      }
      final (payload, size) = imageData(await encode(pixels, minimum));
      final decoded = decodePayload(payload, size, pixels.length);
      expect(decoded.pixels, pixels);
      expect(decoded.clears, greaterThan(1));
      expect(decoded.boundaries.keys.toSet(),
        {for (var width = minimum + 2; width <= 12; width++) width});
      for (final boundary in decoded.boundaries.values) {
        for (final length in [boundary - 1, boundary, boundary + 1]) {
          final prefix = Uint8List.sublistView(pixels, 0, length);
          final (data, bits) = imageData(await encode(prefix, minimum));
          expect(decodePayload(data, bits, length).pixels, prefix,
            reason: 'minimum=$minimum, length=$length');
        }
      }
    });
  }
}
