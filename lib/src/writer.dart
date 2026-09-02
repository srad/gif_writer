import 'dart:async';
import 'dart:typed_data';

import 'color_table.dart';
// `dart:io` reaches this package through exactly one seam, so the core stays
// compilable on the web and `toFile` still exists there — throwing, which is
// honest, rather than being absent and breaking the build.
import 'file_sink.dart' if (dart.library.io) 'file_sink_io.dart';
import 'frame.dart';
import 'lzw.dart';

/// How many times the animation repeats.
class GifRepeat {
  const GifRepeat._(this.count);

  /// Play once and stop. No looping block is written at all.
  static const GifRepeat once = GifRepeat._(-1);

  /// Loop endlessly, which is what almost every animated GIF does.
  static const GifRepeat forever = GifRepeat._(0);

  /// Play [times] times in total. Values below one are treated as [once].
  factory GifRepeat.times(int times) =>
      times < 1 ? once : GifRepeat._(times - 1);

  /// What goes in the Netscape block: zero means forever, otherwise the number
  /// of *additional* plays.
  final int count;
}

/// Writes an animated GIF to a sink, one frame at a time.
///
/// **Nothing is accumulated.** Each frame's compressed bytes go out through the
/// sink as they are produced — at most one 255-byte LZW sub-block is held — so
/// peak memory is a function of one frame, never of the animation's length. That
/// is the whole reason this package exists: the alternatives build the finished
/// file in memory and hand it over at the end, which a long recording on a phone
/// cannot afford.
///
/// The header is written on the **first frame**, not at construction, so a
/// future version can derive the colour table from that frame.
///
/// ```dart
/// final gif = GifWriter(
///   sink,
///   width: 64,
///   height: 64,
///   colors: GifColorTable.packed(<int>[0x000000, 0xFFFFFF]),
/// );
/// await gif.addIndexedFrame(pixels, delay: const Duration(milliseconds: 50));
/// await gif.close();
/// ```
class GifWriter implements StreamConsumer<GifFrame> {
  /// Writes to [sink], which is closed by [close].
  ///
  /// [onFlush] is awaited once per frame and is how back-pressure reaches the
  /// caller. Without it a producer faster than the destination — a tight loop
  /// against a slow disk — would queue frames inside the sink, moving the
  /// buffering this package removes one layer down where nobody looks for it.
  /// `GifWriter.toFile` wires it to `IOSink.flush`.
  GifWriter(
    StreamSink<List<int>> sink, {
    required int width,
    required int height,
    required GifColorTable colors,
    GifRepeat repeat = GifRepeat.forever,
    Future<void> Function()? onFlush,
  }) : _sink = sink,
       _width = _checkDimension(width, 'width'),
       _height = _checkDimension(height, 'height'),
       _colors = colors,
       _repeat = repeat,
       _onFlush = onFlush;

  /// Writes to a file at [path], truncating anything already there.
  ///
  /// **Synchronous on purpose.** `Stream.pipe` takes a `StreamConsumer`, not a
  /// future of one, so an `async` factory would force
  /// `await frames.pipe(await GifWriter.toFile(…))` — awkward enough that people
  /// work around it by collecting frames first, which is the very thing this
  /// package exists to avoid. The sink is opened eagerly and any failure
  /// surfaces from the first [addIndexedFrame].
  ///
  /// Throws `UnsupportedError` on the web, which has no filesystem; construct
  /// [GifWriter] with a sink of your own there.
  factory GifWriter.toFile(
    String path, {
    required int width,
    required int height,
    required GifColorTable colors,
    GifRepeat repeat = GifRepeat.forever,
  }) {
    final sink = openFileSink(path);
    return GifWriter(
      sink,
      width: width,
      height: height,
      colors: colors,
      repeat: repeat,
      onFlush: flusherFor(sink),
    );
  }

  static int _checkDimension(int value, String name) {
    if (value < 1 || value > 0xFFFF) {
      throw ArgumentError.value(value, name, 'must be 1 to 65535');
    }
    return value;
  }

  final StreamSink<List<int>> _sink;
  final int _width;
  final int _height;
  final GifColorTable _colors;
  final GifRepeat _repeat;
  final Future<void> Function()? _onFlush;

  bool _headerWritten = false;
  bool _closed = false;
  int _frames = 0;

  /// How many frames have been written so far.
  int get frameCount => _frames;

  /// Appends a frame of palette indices, one byte per pixel.
  ///
  /// [indices] must be exactly `width * height` long and every byte must be a
  /// valid index into the colour table — this is checked, because an out-of-range
  /// index produces a file that decodes to the wrong colours rather than failing.
  ///
  /// [delay] is rounded to hundredths of a second, which is all GIF stores.
  /// **A delay under two hundredths is not honoured by most viewers**, which
  /// substitute ten; the value is written as given rather than silently clamped,
  /// so the file says what was asked for, but do not expect 60 fps to play as
  /// 60 fps anywhere.
  Future<void> addIndexedFrame(
    Uint8List indices, {
    Duration delay = Duration.zero,
  }) async {
    if (_closed) {
      throw StateError('the writer is closed');
    }
    final expected = _width * _height;
    if (indices.length != expected) {
      throw ArgumentError.value(
        indices.length,
        'indices',
        'expected $expected bytes for ${_width}x$_height',
      );
    }
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= _colors.length) {
        throw ArgumentError(
          'pixel $i is index ${indices[i]}, outside the '
          '${_colors.length}-colour table',
        );
      }
    }

    if (!_headerWritten) {
      _writeHeader();
      _headerWritten = true;
    }

    _writeGraphicControl(delay: delay);
    _writeImageDescriptor();
    gifLzwCompress(
      indices: indices,
      minCodeSize: gifMinCodeSize(colorCount: _colors.length),
      emit: _sink.add,
    );
    _frames++;

    // Once per frame, not once per sub-block: flushing per block would trade the
    // memory win for a syscall storm.
    await _onFlush?.call();
  }

  void _writeHeader() {
    _sink.add(const <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // GIF89a

    final bits = _colors.bitsPerPixel;
    _sink.add(<int>[
      _width & 0xFF, (_width >> 8) & 0xFF,
      _height & 0xFF, (_height >> 8) & 0xFF,
      // Global table present, 8-bit colour resolution, unsorted, and the table's
      // size as an exponent less one.
      0x80 | 0x70 | (bits - 1),
      0, // background colour index
      0, // pixel aspect ratio: none
    ]);
    _sink.add(_colors.toBytes());

    // The looping block belongs here — after the table, before any frame — and
    // is the only way GIF expresses "repeat". Omitted entirely for a single
    // play, because a Netscape block saying "loop once more" is not the same
    // thing as no block at all.
    if (_repeat != GifRepeat.once) {
      _sink.add(<int>[
        0x21, 0xFF, 0x0B, //
        0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, // NETSCAPE
        0x32, 0x2E, 0x30, // 2.0
        0x03, 0x01,
        _repeat.count & 0xFF, (_repeat.count >> 8) & 0xFF,
        0x00,
      ]);
    }
  }

  void _writeGraphicControl({required Duration delay}) {
    // Hundredths, rounded rather than truncated: at 50 ms a truncation would
    // write 5 and a round writes 5, but at 15 ms truncation loses a fifth of the
    // frame's time and the animation drifts over hundreds of frames.
    final centiseconds = (delay.inMicroseconds / 10000).round().clamp(0, 0xFFFF);
    _sink.add(<int>[
      0x21, 0xF9, 0x04,
      0x00, // no disposal, no user input, no transparency — 0.3.0 adds these
      centiseconds & 0xFF, (centiseconds >> 8) & 0xFF,
      0x00, // transparent colour index, unused while the flag is clear
      0x00,
    ]);
  }

  void _writeImageDescriptor() {
    _sink.add(<int>[
      0x2C,
      0, 0, 0, 0, // left, top
      _width & 0xFF, (_width >> 8) & 0xFF,
      _height & 0xFF, (_height >> 8) & 0xFF,
      // No local table — every frame uses the global one — not interlaced.
      0x00,
    ]);
  }

  /// Writes the trailer and closes the sink.
  ///
  /// A GIF with no frames is still written, header and all: a zero-frame file is
  /// a valid, empty animation, and throwing here would strand a caller whose
  /// stream happened to be empty.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_headerWritten) {
      _writeHeader();
      _headerWritten = true;
    }
    _sink.add(const <int>[0x3B]);
    await _onFlush?.call();
    await _sink.close();
  }

  /// Consumes a stream of frames, so `frames.pipe(writer)` works.
  @override
  Future<void> addStream(Stream<GifFrame> stream) async {
    await for (final frame in stream) {
      await addIndexedFrame(frame.indices, delay: frame.delay);
    }
  }
}
