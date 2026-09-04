import 'dart:async';
import 'dart:typed_data';

import 'byte_sink.dart';
import 'color_mapper.dart';
import 'color_table.dart';
import 'dither.dart';
// `dart:io` reaches this package through exactly one seam, so the core stays
// compilable on the web and `toFile` still exists there — throwing, which is
// honest, rather than being absent and breaking the build.
import 'file_sink.dart' if (dart.library.io) 'file_sink_io.dart';
import 'frame.dart';
import 'lzw.dart';
import 'quantizer.dart';

/// How many times the animation repeats.
class GifRepeat {
  const GifRepeat._(this.count);

  /// Play once and stop. No looping block is written at all.
  static const GifRepeat once = GifRepeat._(-1);

  /// Loop endlessly, which is what almost every animated GIF does.
  static const GifRepeat forever = GifRepeat._(0);

  /// Play [times] times in total. One or fewer is [once].
  ///
  /// **The boundary is `<= 1`, not `< 1`.** The stored value is the number of
  /// *additional* plays, so `times(1)` naively becomes `_(0)` — and zero is the
  /// code for **forever**. Asking for a single play produced an endless loop,
  /// and nothing about the file looked wrong: every pixel decoded perfectly and
  /// it simply never stopped.
  ///
  /// **The upper bound is refused rather than truncated**, for the same reason.
  /// The Netscape block stores the count in two bytes, so anything past 65536
  /// total plays cannot be written: `times(70000)` would store 69999 and emit
  /// `69999 & 0xFFFF` — a file that asks for 4463 plays, decodes perfectly, and
  /// is wrong in the one way a round-trip test cannot see.
  factory GifRepeat.times(int times) {
    if (times > _maxTimes) {
      throw ArgumentError.value(
        times,
        'times',
        'at most $_maxTimes; the Netscape block counts plays in two bytes',
      );
    }
    return times <= 1 ? once : GifRepeat._(times - 1);
  }

  /// The most total plays the two-byte Netscape count can express: it holds
  /// `times - 1`, so 65536 plays stores 65535.
  static const int _maxTimes = 0xFFFF + 1;

  /// What goes in the Netscape block: zero means forever, otherwise the number
  /// of *additional* plays.
  final int count;

  /// Value equality: two repeats are equal when they encode the same play count.
  /// `GifRepeat.times(1)` equals [once] because `times` folds it to exactly that.
  @override
  bool operator ==(Object other) => other is GifRepeat && other.count == count;

  @override
  int get hashCode => count.hashCode;
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
/// The header is written on the **first frame**, not at construction — which is
/// what lets the writer derive a colour table from that frame when none is given.
///
/// **Concurrent `add*Frame` calls are safe**, and emit their frames in call
/// order. Every mutation of the writer's shared state — `_scratch`, the LZW
/// encoder, the staging buffer, the header/frame counters — happens
/// *synchronously*, before the single `await _onFlush?.call()` at the end of
/// `_writeIndexed`. So a call runs its whole encode-and-flush uninterrupted; by
/// the time it suspends at that await, the frame's bytes are already out and the
/// shared buffers are free for the next call to reuse. **This invariant is
/// load-bearing and fragile: moving any `await` earlier in the write path —
/// ahead of the encode — would let a second call clobber `_scratch` or the LZW
/// dictionary mid-frame, with no error to show for it.**
///
/// Three ways in: [addIndexedFrame] takes one byte per pixel and is byte-exact,
/// while [addRgbFrame] and [addRgbaFrame] map and dither. All three go onto the
/// colour table — either the one passed as `colors:`, or, if that is left unset,
/// the one derived from the first RGB or RGBA frame by the writer's [GifQuantizer].
/// An indexed frame cannot derive a table, so it requires `colors:`.
///
/// ```dart
/// final gif = GifWriter(
///   sink,
///   width: 64,
///   height: 64,
///   colors: GifColorTable.packed(<int>[0x000000, 0xFF5500, 0xFFFFFF]),
///   dither: GifDither.blueNoise, // the default; only the RGB paths use it
/// );
/// await gif.addIndexedFrame(indices, delay: const Duration(milliseconds: 50));
/// await gif.addRgbFrame(rgb, delay: const Duration(milliseconds: 50));
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
  ///
  /// [bufferSize] is the staging buffer the encoder gathers small writes into
  /// before handing them on. It is the package's entire fixed overhead besides
  /// the LZW tables, and it does not grow: measured, batching here took a 5.8 MB
  /// animation from 24,365 sink writes to 121, and lifted throughput by about
  /// half.
  /// Lower it on a memory budget; below about a kilobyte the syscalls start to
  /// cost more than the buffer saves.
  ///
  /// [dither] applies only to the RGB entry points; [addIndexedFrame] never
  /// touches it, because indices are already exact. It defaults to
  /// [GifDither.blueNoise] — see [GifDither] for why an ordered dither and not
  /// Floyd–Steinberg.
  ///
  /// [colors] is **optional**. Leave it unset to have the writer derive a global
  /// table from the first RGB or RGBA frame; supply one when you already have a
  /// palette, or want indexed frames (which cannot derive a table). [quantizer]
  /// chooses how that derivation is done and is ignored when [colors] is given —
  /// see [GifQuantizer].
  GifWriter(
    StreamSink<List<int>> sink, {
    required int width,
    required int height,
    GifColorTable? colors,
    GifRepeat repeat = GifRepeat.forever,
    GifDither dither = GifDither.blueNoise,
    GifQuantizer quantizer = GifQuantizer.octree,
    Future<void> Function()? onFlush,
    int bufferSize = 64 * 1024,
  }) : _out = BufferedByteSink(sink, capacity: bufferSize),
       _width = _checkDimension(width, 'width'),
       _height = _checkDimension(height, 'height'),
       _colors = colors,
       _repeat = repeat,
       _dither = dither,
       _quantizer = quantizer,
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
    GifColorTable? colors,
    GifRepeat repeat = GifRepeat.forever,
    GifDither dither = GifDither.blueNoise,
    GifQuantizer quantizer = GifQuantizer.octree,
  }) {
    final sink = openFileSink(path);
    return GifWriter(
      sink,
      width: width,
      height: height,
      colors: colors,
      repeat: repeat,
      dither: dither,
      quantizer: quantizer,
      onFlush: flusherFor(sink),
    );
  }

  /// The smallest [bufferSize] accepted.
  ///
  /// A GIF sub-block is a length byte plus up to 255 of data, written straight
  /// into the staging buffer and patched afterwards. A buffer that could fill
  /// mid-block would leave that patch writing to a stale position — a corrupt
  /// file with nothing thrown — so anything smaller is refused rather than
  /// silently mishandled.
  static const int minBufferSize = BufferedByteSink.minCapacity;

  static int _checkDimension(int value, String name) {
    if (value < 1 || value > 0xFFFF) {
      throw ArgumentError.value(value, name, 'must be 1 to 65535');
    }
    return value;
  }

  final BufferedByteSink _out;
  final int _width;
  final int _height;

  /// The global colour table. Null until known: either passed as `colors:`, or
  /// derived from the first RGB/RGBA frame. Read only after that point.
  GifColorTable? _colors;
  final GifRepeat _repeat;
  final GifDither _dither;
  final GifQuantizer _quantizer;
  final Future<void> Function()? _onFlush;

  /// Built on the **first RGB frame**, never for an indexed-only animation.
  ///
  /// The colour cache is 96 kB and the dither's error rows are another
  /// `12 x width`. A caller that only ever passes indices — which is every
  /// caller from 0.1.x — pays none of it.
  ColorMapper? _mapper;
  DitherRunner? _runner;

  /// Reused across frames, like everything else here: one byte per pixel, so it
  /// is the one buffer that scales with the frame rather than the animation.
  Uint8List? _scratch;

  /// Where RGBA is flattened before mapping. Allocated only if [addRgbaFrame]
  /// is ever called.
  Uint8List? _rgbScratch;

  /// One encoder for the whole animation. Its hash tables come to about 128 kB
  /// that a per-frame encoder would allocate and throw away on every frame.
  final GifLzwEncoder _lzw = GifLzwEncoder();

  /// The fixed blocks, filled in place rather than rebuilt as a list literal per
  /// frame.
  final Uint8List _control = Uint8List.fromList(<int>[
    // The trailing `//` holds this on one line; without it the formatter gives
    // each byte a line of its own, which hides the block's shape.
    0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, //
  ]);
  final Uint8List _descriptor = Uint8List(10);

  /// Whether any byte is a legal index, which makes the per-pixel check in
  /// [addIndexedFrame] unnecessary. A getter, not a `late final`, because the
  /// table may not exist yet when the writer is built — reading it before the
  /// palette is known would be a bug, and the indexed path guards against that
  /// first.
  bool get _everyByteValid => _colors!.length == 256;

  bool _headerWritten = false;
  bool _closed = false;
  int _frames = 0;

  /// How many frames have been written so far.
  int get frameCount => _frames;

  /// Completes when the underlying sink is done, and is how a sink error that
  /// arrives **asynchronously** — after the `add` that caused it already
  /// returned — reaches the caller.
  ///
  /// For [GifWriter.toFile] the per-frame flush surfaces most failures already;
  /// this matters for the "write to a socket" case, where a peer resetting the
  /// connection can complete the sink's `done` with an error out of band. Await
  /// it alongside your writes, or rely on [close], which now awaits it too.
  Future<void> get done => _out.done;

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
    if (_colors == null) {
      // Indices address a palette; they cannot conjure one. A writer left to
      // derive its table needs an RGB or RGBA frame to derive it from.
      throw StateError(
        'no colour table: pass `colors:` to the constructor, or add an RGB or '
        'RGBA frame first so one can be derived',
      );
    }
    final expected = _width * _height;
    if (indices.length != expected) {
      throw ArgumentError.value(
        indices.length,
        'indices',
        'expected $expected bytes for ${_width}x$_height',
      );
    }
    await _writeIndexed(indices: indices, delay: delay, validate: true);
  }

  /// Appends a frame of RGB pixels, three bytes each, mapped to the colour table.
  ///
  /// Colours not in the table are dithered between the two nearest entries, using
  /// the writer's [GifDither]; a pixel that is *exactly* a table colour always
  /// maps to that entry, so palettised content survives this path unchanged.
  ///
  /// **If the writer was built without `colors:`, the very first such frame
  /// derives the global table** — from this frame's pixels alone, via the
  /// writer's [GifQuantizer]. Later frames map onto that table like any other,
  /// so a scene whose palette shifts partway through is mapped onto the colours
  /// the *first* frame needed. Quantise a representative image yourself with
  /// `GifColorTable.quantize` and pass it as `colors:` when that is not what you
  /// want.
  Future<void> addRgbFrame(
    Uint8List rgb, {
    Duration delay = Duration.zero,
  }) async {
    if (_closed) {
      throw StateError('the writer is closed');
    }
    final expected = _width * _height * 3;
    if (rgb.length != expected) {
      throw ArgumentError.value(
        rgb.length,
        'rgb',
        'expected $expected bytes for ${_width}x$_height at 3 bytes per pixel',
      );
    }
    // Derive the table from the first frame if none was supplied — before
    // mapping, which needs it, and before the header, which is written from it.
    _colors ??= GifColorTable.quantize(rgb, quantizer: _quantizer);
    final indices = _map(rgb);
    // No range check: these indices came from our own mapper, which cannot
    // produce one outside the table. The check exists for bytes a caller
    // supplied, and it is a whole extra pass over every pixel.
    await _writeIndexed(indices: indices, delay: delay, validate: false);
  }

  /// Appends a frame of RGBA pixels, four bytes each, composited over
  /// [background] and then mapped as [addRgbFrame] does.
  ///
  /// [background] is **required rather than defaulted**. GIF transparency is not
  /// implemented yet, so alpha has to go somewhere; picking white silently would
  /// give a wrong colour for every semi-transparent pixel, and the caller is the
  /// only one who knows what the image sits on.
  Future<void> addRgbaFrame(
    Uint8List rgba, {
    required int background,
    Duration delay = Duration.zero,
  }) async {
    if (_closed) {
      throw StateError('the writer is closed');
    }
    final expected = _width * _height * 4;
    if (rgba.length != expected) {
      throw ArgumentError.value(
        rgba.length,
        'rgba',
        'expected $expected bytes for ${_width}x$_height at 4 bytes per pixel',
      );
    }
    // Composite first, then derive from the *opaque* result — quantising the raw
    // RGBA would build a palette around colours the alpha never lets through.
    final rgb = _composite(rgba: rgba, background: background);
    _colors ??= GifColorTable.quantize(rgb, quantizer: _quantizer);
    await _writeIndexed(indices: _map(rgb), delay: delay, validate: false);
  }

  /// Flattens RGBA onto an opaque background, in place in the scratch buffer.
  Uint8List _composite({required Uint8List rgba, required int background}) {
    final br = (background >> 16) & 0xFF;
    final bg = (background >> 8) & 0xFF;
    final bb = background & 0xFF;
    final rgb = _rgbScratch ??= Uint8List(_width * _height * 3);
    for (var i = 0, p = 0; p < rgb.length; i += 4, p += 3) {
      final a = rgba[i + 3];
      if (a == 255) {
        rgb[p] = rgba[i];
        rgb[p + 1] = rgba[i + 1];
        rgb[p + 2] = rgba[i + 2];
      } else {
        // Rounded, not truncated: `+ 127` costs nothing and stops a long
        // gradient drifting a level darker than it should be.
        rgb[p] = (rgba[i] * a + br * (255 - a) + 127) ~/ 255;
        rgb[p + 1] = (rgba[i + 1] * a + bg * (255 - a) + 127) ~/ 255;
        rgb[p + 2] = (rgba[i + 2] * a + bb * (255 - a) + 127) ~/ 255;
      }
    }
    return rgb;
  }

  Uint8List _map(Uint8List rgb) {
    final mapper = _mapper ??= ColorMapper(_colors!);
    final runner =
        _runner ??= DitherRunner(
          dither: _dither,
          mapper: mapper,
          width: _width,
        );
    final out = _scratch ??= Uint8List(_width * _height);
    runner.mapRgb(rgb: rgb, out: out);
    return out;
  }

  Future<void> _writeIndexed({
    required Uint8List indices,
    required Duration delay,
    required bool validate,
  }) async {
    // Skipped entirely for a full table, where no byte can be out of range —
    // and a full table is the common case, since anything that quantises
    // produces 256 colours. This is a whole extra pass over every pixel, so
    // "free when it cannot fail" is worth the branch.
    if (validate && !_everyByteValid) {
      final limit = _colors!.length;
      // One OR per pixel, then a single comparison — rather than a compare and a
      // branch per pixel, which measured as most of the gap against an encoder
      // that does not check at all.
      //
      // The OR can only *overstate* the maximum: bits from different pixels
      // combine, so 1 and 2 look like 3. That is why a positive result is not
      // the error — it only buys the precise pass below, which is the one that
      // throws. Cannot produce a false negative, because a byte at or above the
      // limit always sets a bit that survives the OR.
      var combined = 0;
      for (var i = 0; i < indices.length; i++) {
        combined |= indices[i];
      }
      if (combined >= limit) {
        for (var i = 0; i < indices.length; i++) {
          if (indices[i] >= limit) {
            throw ArgumentError(
              'pixel $i is index ${indices[i]}, outside the '
              '$limit-colour table',
            );
          }
        }
      }
    }

    if (!_headerWritten) {
      _writeHeader();
      _headerWritten = true;
    }

    _writeGraphicControl(delay: delay);
    _writeImageDescriptor();
    _lzw.encode(
      indices: indices,
      minCodeSize: gifMinCodeSize(colorCount: _colors!.length),
      out: _out,
    );
    _frames++;

    // The frame's bytes leave here, before the next one is encoded: the staging
    // buffer is bounded, but a frame must not sit in it waiting for the next.
    _out.flush();
    // Once per frame, not once per sub-block: flushing per block would trade the
    // memory win for a syscall storm.
    await _onFlush?.call();
  }

  void _writeHeader() {
    // Written once per file, so a list literal here costs nothing worth naming.
    _out.add(const <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // GIF89a

    final colors = _colors;
    if (colors == null) {
      // Reached only by closing a writer that was left to derive its table and
      // never got a frame to derive it from. GIF89a allows *no* global colour
      // table — flag clear, size bits zero, no table bytes — which is the honest
      // encoding of "there were no colours". Still a valid, if empty, file.
      _out.add(<int>[
        _width & 0xFF, (_width >> 8) & 0xFF,
        _height & 0xFF, (_height >> 8) & 0xFF,
        0x70, // no global table, 8-bit colour resolution, size 0
        0, // background colour index
        0, // pixel aspect ratio: none
      ]);
    } else {
      final bits = colors.bitsPerPixel;
      _out.add(<int>[
        _width & 0xFF, (_width >> 8) & 0xFF,
        _height & 0xFF, (_height >> 8) & 0xFF,
        // Global table present, 8-bit colour resolution, unsorted, and the
        // table's size as an exponent less one.
        0x80 | 0x70 | (bits - 1),
        0, // background colour index
        0, // pixel aspect ratio: none
      ]);
      _out.add(colors.toBytes());
    }

    // The looping block belongs here — after the table, before any frame — and
    // is the only way GIF expresses "repeat". Omitted entirely for a single
    // play, because a Netscape block saying "loop once more" is not the same
    // thing as no block at all.
    //
    // Tested on the count rather than on identity with `GifRepeat.once`: that
    // only works while `once` is the sole instance holding a negative count,
    // which is true today and is not a property anything enforces.
    if (_repeat.count >= 0) {
      _out.add(<int>[
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
    // Hundredths, rounded rather than truncated: at 15 ms truncation loses a
    // fifth of the frame's time, and over a few hundred frames the animation
    // visibly drifts against whatever it was timed to.
    final centiseconds = (delay.inMicroseconds / 10000).round().clamp(
      0,
      0xFFFF,
    );
    // Filled in place: the two bytes that vary are the delay, and the rest of
    // this block is the same for every frame of every animation.
    _control[4] = centiseconds & 0xFF;
    _control[5] = (centiseconds >> 8) & 0xFF;
    _out.add(_control);
  }

  void _writeImageDescriptor() {
    _descriptor[0] = 0x2C;
    // left and top stay zero; the frame is the whole logical screen until 0.4.0
    // adds diffing.
    _descriptor[5] = _width & 0xFF;
    _descriptor[6] = (_width >> 8) & 0xFF;
    _descriptor[7] = _height & 0xFF;
    _descriptor[8] = (_height >> 8) & 0xFF;
    // No local table — every frame uses the global one — not interlaced.
    _descriptor[9] = 0x00;
    _out.add(_descriptor);
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
    _out.addByte(0x3B);
    _out.flush();
    await _onFlush?.call();
    await _out.close();
    // Surface a sink error that was reported through `done` rather than through
    // `close`. `close` above has already closed the sink, so `done` is resolved
    // by now — awaiting it here just propagates its error out of `close`, so a
    // caller who only awaits `close` still sees a failure that arrived mid-stream.
    await _out.done;
  }

  /// Consumes a stream of frames, so `frames.pipe(writer)` works.
  @override
  Future<void> addStream(Stream<GifFrame> stream) async {
    await for (final frame in stream) {
      switch (frame.kind) {
        case GifFrameKind.indexed:
          await addIndexedFrame(frame.pixels, delay: frame.delay);
        case GifFrameKind.rgb:
          await addRgbFrame(frame.pixels, delay: frame.delay);
        case GifFrameKind.rgba:
          await addRgbaFrame(
            frame.pixels,
            background: frame.background,
            delay: frame.delay,
          );
      }
    }
  }
}
