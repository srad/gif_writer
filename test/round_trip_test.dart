import 'dart:async';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// Everything this package writes, decoded by somebody else.
///
/// `package:image` is a **dev dependency only**, and it is here for one reason:
/// it is an independent implementation. Checking our encoder against a decoder
/// of our own would be circular — both would share whatever misunderstanding of
/// the format we happen to have — and the bugs that survive longest are exactly
/// the ones a test cannot see because it is asking the wrong oracle.
/// Collects everything a writer emits.
///
/// Not a convenience: the streaming tests assert on *when* bytes arrive, so this
/// records that as well as the bytes themselves.
final class RecordingSink implements StreamSink<List<int>> {
  final BytesBuilder _bytes = BytesBuilder(copy: true);

  /// The total emitted after each `add`, so a test can see the file grow.
  final List<int> lengthAfterEachAdd = <int>[];
  bool closed = false;

  @override
  void add(List<int> data) {
    _bytes.add(data);
    lengthAfterEachAdd.add(_bytes.length);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnimplementedError();

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> get done => Future<void>.value();

  int get length => _bytes.length;

  Uint8List get result => _bytes.toBytes();
}

void main() {
  GifColorTable grays(int count) => GifColorTable.packed(<int>[
    for (var i = 0; i < count; i++)
      (i * 255 ~/ (count - 1)) * 0x010101,
  ]);

  /// Encodes [frames] and hands back what `package:image` reads out of it.
  Future<img.Image> roundTrip({
    required List<Uint8List> frames,
    required int width,
    required int height,
    required GifColorTable colors,
  }) async {
    final sink = RecordingSink();
    final gif = GifWriter(
      sink,
      width: width,
      height: height,
      colors: colors,
    );
    for (final frame in frames) {
      await gif.addIndexedFrame(frame, delay: const Duration(milliseconds: 40));
    }
    await gif.close();

    final decoded = img.GifDecoder().decode(sink.result);
    expect(decoded, isNotNull, reason: 'package:image could not read the file');
    return decoded!;
  }

  test('a single frame decodes to exactly the pixels it was given', () async {
    // Byte-exact, not approximate: with a supplied table and no dithering there
    // is no quantiser anywhere in the path, so anything but equality is a bug in
    // the LZW or the container.
    const width = 7;
    const height = 5;
    final colors = grays(4);
    final pixels = Uint8List.fromList(<int>[
      for (var i = 0; i < width * height; i++) i % 4,
    ]);

    final animation = await roundTrip(
      frames: <Uint8List>[pixels],
      width: width,
      height: height,
      colors: colors,
    );

    expect(animation.frames, hasLength(1));
    final frame = animation.frames.first;
    expect(frame.width, width);
    expect(frame.height, height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final expected = colors[pixels[y * width + x]];
        final actual = frame.getPixel(x, y);
        expect(
          (actual.r.toInt() << 16) | (actual.g.toInt() << 8) | actual.b.toInt(),
          expected,
          reason: 'pixel ($x, $y)',
        );
      }
    }
  });

  test('every frame of an animation survives, in order', () async {
    const size = 4;
    final colors = grays(8);
    final frames = <Uint8List>[
      for (var f = 0; f < 6; f++)
        Uint8List.fromList(<int>[
          for (var i = 0; i < size * size; i++) (i + f) % 8,
        ]),
    ];

    final animation = await roundTrip(
      frames: frames,
      width: size,
      height: size,
      colors: colors,
    );

    expect(animation.frames, hasLength(frames.length));
    for (var f = 0; f < frames.length; f++) {
      final frame = animation.frames[f];
      for (var i = 0; i < size * size; i++) {
        final pixel = frame.getPixel(i % size, i ~/ size);
        expect(
          (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt(),
          colors[frames[f][i]],
          reason: 'frame $f, pixel $i',
        );
      }
    }
  });

  group('sizes where LZW block boundaries go wrong', () {
    // The compressed stream is packed into 255-byte sub-blocks and the code
    // width grows as the dictionary fills. Both are off-by-one country, and both
    // depend on the pixel count rather than on anything the caller sees — so the
    // sizes worth testing are the awkward ones, not the round ones.
    for (final (name, width, height) in <(String, int, int)>[
      ('a single pixel', 1, 1),
      ('one row', 17, 1),
      ('one column', 1, 23),
      ('not a multiple of eight', 13, 11),
      ('large enough to refill the dictionary', 200, 200),
    ]) {
      test(name, () async {
        final colors = grays(16);
        // A pattern that does not compress into a handful of codes: a solid
        // frame would exercise almost none of the dictionary.
        final pixels = Uint8List.fromList(<int>[
          for (var i = 0; i < width * height; i++) (i * 7 + i ~/ 3) % 16,
        ]);

        final animation = await roundTrip(
          frames: <Uint8List>[pixels],
          width: width,
          height: height,
          colors: colors,
        );

        final frame = animation.frames.single;
        for (var i = 0; i < width * height; i++) {
          final pixel = frame.getPixel(i % width, i ~/ width);
          expect(
            (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt(),
            colors[pixels[i]],
            reason: 'pixel $i of $width x $height',
          );
        }
      });
    }
  });

  test('a full 256-colour table round-trips', () async {
    // The widest table, where the minimum code size is 8 and the first code
    // width is 9 — the case a two-colour test never reaches.
    final colors = GifColorTable.packed(<int>[
      for (var i = 0; i < 256; i++) (i << 16) | (i << 8) | i,
    ]);
    final pixels = Uint8List.fromList(<int>[
      for (var i = 0; i < 256; i++) i,
    ]);

    final animation = await roundTrip(
      frames: <Uint8List>[pixels],
      width: 16,
      height: 16,
      colors: colors,
    );

    final frame = animation.frames.single;
    for (var i = 0; i < 256; i++) {
      final pixel = frame.getPixel(i % 16, i ~/ 16);
      expect(pixel.r.toInt(), i, reason: 'pixel $i');
    }
  });
}
