import 'package:gif_writer/gif_writer.dart';
import 'package:test/test.dart';

/// The colour table, and the padding rule that is easy to get wrong.
///
/// GIF has no way to say "five colours". The size field is an **exponent**, so a
/// table is always 2, 4, 8 … 256 entries and the unused tail is black. Get the
/// exponent wrong and the decoder reads the wrong number of bytes before the
/// first frame — every byte after it is then misinterpreted, which looks like a
/// corrupt file rather than an off-by-one.
void main() {
  group('construction', () {
    test('packed and rgb describe the same table', () {
      final packed = GifColorTable.packed(<int>[0x102030, 0xA0B0C0]);
      final rgb = GifColorTable.rgb(<int>[0x10, 0x20, 0x30, 0xA0, 0xB0, 0xC0]);
      expect(packed.length, rgb.length);
      expect(packed[0], rgb[0]);
      expect(packed[1], rgb[1]);
      expect(packed.toBytes(), rgb.toBytes());
    });

    test('a colour reads back exactly as it was given', () {
      final table = GifColorTable.packed(<int>[0x000000, 0x123456, 0xFFFFFF]);
      expect(table[0], 0x000000);
      expect(table[1], 0x123456);
      expect(table[2], 0xFFFFFF);
    });

    test('the bytes are copied, so a caller may reuse its buffer', () {
      // The table is written into the file's header long after construction. A
      // view would let a caller's later write change a header already claimed to
      // be fixed.
      final source = <int>[0x10, 0x20, 0x30];
      final table = GifColorTable.rgb(source);
      source[0] = 0xFF;
      expect(table[0], 0x102030);
    });

    test('an empty or oversized table is refused', () {
      expect(() => GifColorTable.rgb(<int>[]), throwsArgumentError);
      expect(
        () => GifColorTable.packed(<int>[for (var i = 0; i < 257; i++) i]),
        throwsArgumentError,
      );
    });

    test('a byte count that is not a multiple of three is refused', () {
      // Silently dropping the tail would give a table shorter than the caller
      // believes, and every index past it would then be out of range.
      expect(() => GifColorTable.rgb(<int>[1, 2, 3, 4]), throwsArgumentError);
    });
  });

  group('padding to a power of two', () {
    test('an exact power of two is not padded', () {
      for (final count in <int>[2, 4, 8, 16, 32, 64, 128, 256]) {
        final table = GifColorTable.packed(<int>[
          for (var i = 0; i < count; i++) i,
        ]);
        expect(table.toBytes(), hasLength(count * 3), reason: '$count colours');
        expect(1 << table.bitsPerPixel, count, reason: '$count colours');
      }
    });

    test('anything else is padded up, with black in the tail', () {
      final table = GifColorTable.packed(<int>[0xFF0000, 0x00FF00, 0x0000FF]);
      expect(table.length, 3, reason: 'the caller still gave three colours');
      expect(1 << table.bitsPerPixel, 4, reason: 'but four are written');
      final bytes = table.toBytes();
      expect(bytes, hasLength(12));
      expect(bytes.sublist(9), <int>[0, 0, 0], reason: 'the tail is black');
    });

    test('a single colour still writes the two-entry minimum', () {
      // The smallest legal table is two entries; there is no one-bit size field.
      final table = GifColorTable.packed(<int>[0x336699]);
      expect(table.length, 1);
      expect(table.bitsPerPixel, 1);
      expect(table.toBytes(), hasLength(6));
    });

    test('bitsPerPixel is the exponent the header writes', () {
      // Off by one here shifts every byte after the table.
      const expected = <int, int>{
        1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 8: 3, 9: 4,
        16: 4, 17: 5, 32: 5, 64: 6, 128: 7, 129: 8, 256: 8,
      };
      expected.forEach((count, bits) {
        final table = GifColorTable.packed(<int>[
          for (var i = 0; i < count; i++) i,
        ]);
        expect(table.bitsPerPixel, bits, reason: '$count colours');
      });
    });
  });
}
