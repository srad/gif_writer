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
import 'transparency.dart';

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
/// **Await each frame to keep memory bounded.** Each frame's compressed bytes go
/// out through a fixed staging buffer, so awaited streaming retains one frame
/// rather than accumulating the animation. The destination must also drain its
/// output; an output-collecting sink still retains the complete encoded file.
///
/// The header is written on the **first frame**, not at construction — which is
/// what lets the writer derive a colour table from that frame when none is given.
///
/// **Concurrent `add*Frame` calls are queued in call order**, including the
/// awaited sink flush. Input buffers are borrowed: keep them unchanged until
/// their returned futures complete. A backlog retains those buffers; awaiting
/// each frame or using [addStream] keeps memory independent of animation length.
///
/// Three ways in: [addIndexedFrame] takes one byte per pixel and is byte-exact,
/// while [addRgbFrame] and [addRgbaFrame] map and dither. All three go onto the
/// colour table — either the one passed as `colors:`, or, if that is left unset,
/// the one derived from the first RGB or RGBA frame by the writer's [GifQuantizer].
/// An indexed frame requires `colors:` or a table derived by an earlier RGB/RGBA
/// frame; indices alone cannot derive a palette.
///
/// ```dart
/// final gif = GifWriter(
///   sink,
///   width: 64,
///   height: 64,
///   colors: GifColorTable.packed(<int>[0x000000, 0xFF5500, 0xFFFFFF]),
///   dither: GifDither.blueNoise, // the default; only the RGB paths use it
/// );
/// try {
///   await gif.addIndexedFrame(indices, delay: const Duration(milliseconds: 50));
///   await gif.addRgbFrame(rgb, delay: const Duration(milliseconds: 50));
/// } finally {
///   await gif.close();
/// }
/// ```
class GifWriter implements StreamConsumer<GifFrame> {
  /// Writes to [sink], which is closed by [close].
  ///
  /// [onFlush] is awaited once per frame and is how back-pressure reaches the
  /// caller. Without it a producer faster than the destination — a tight loop
  /// against a slow disk — would queue frames inside the sink, moving the
  /// buffering this package removes one layer down where nobody looks for it.
  /// `GifWriter.toFile` wires it to `IOSink.flush`.
  /// The callback must only drain the sink; awaiting another write or [close]
  /// on this writer from inside it would wait on the operation running it.
  ///
  /// [bufferSize] is the staging buffer the encoder gathers small writes into
  /// before handing them on. The indexed path also retains its LZW tables and
  /// small runtime objects; RGB/RGBA paths allocate additional mapping and scratch
  /// storage. The staging buffer does not grow: batching took a 5.8 MiB
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
  ///
  /// [transparency], when given, turns on GIF's binary transparency: one palette
  /// slot is reserved as the transparent index, `background` on [addRgbaFrame]
  /// becomes optional, and every frame is marked with the transparent flag and a
  /// disposal method. A supplied [colors] must then hold at most 255 entries, to
  /// leave the slot free; a derived table is quantised to 255. Left unset, none
  /// of that happens and the writer behaves exactly as before. See
  /// [GifTransparency].
  GifWriter(
    StreamSink<List<int>> sink, {
    required int width,
    required int height,
    GifColorTable? colors,
    GifRepeat repeat = GifRepeat.forever,
    GifDither dither = GifDither.blueNoise,
    GifQuantizer quantizer = GifQuantizer.octree,
    GifTransparency? transparency,
    Future<void> Function()? onFlush,
    int bufferSize = 64 * 1024,
  }) : _out = BufferedByteSink(sink, capacity: bufferSize),
       _width = _checkDimension(width, 'width'),
       _height = _checkDimension(height, 'height'),
       _colors = colors,
       _repeat = repeat,
       _dither = dither,
       _quantizer = quantizer,
       _transparency = transparency,
       _onFlush = onFlush {
    // A supplied table is reserved eagerly, so a full one is refused now rather
    // than on the first frame, and so [transparentIndex] is known before any
    // indexed frame that wants to place a hole itself. A derived table is
    // reserved on the first frame instead, where the colours are known.
    if (transparency != null && colors != null) {
      _colors = _withTransparentSlot(colors);
      _transparentIndex = _colors!.length - 1;
    }
    _sinkDone = _out.done;
    // Observe once, before an asynchronous error can go unhandled. A listener
    // per frame on a long-lived `done` future would retain the entire history.
    unawaited(_sinkDone.then<void>((_) {}, onError: _recordFailure));
  }

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
    GifTransparency? transparency,
  }) {
    _checkDimension(width, 'width');
    _checkDimension(height, 'height');
    if (transparency != null && colors != null) {
      _checkTransparentPalette(colors);
    }
    final sink = openFileSink(path);
    return GifWriter(
      sink,
      width: width,
      height: height,
      colors: colors,
      repeat: repeat,
      dither: dither,
      quantizer: quantizer,
      transparency: transparency,
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
  final GifTransparency? _transparency;
  final Future<void> Function()? _onFlush;

  /// The RGB stored in the reserved transparent slot. Never rendered — a decoder
  /// draws nothing where the index appears — so its value is cosmetic; black
  /// keeps the padded table honest.
  static const int _transparentColor = 0x000000;

  /// The reserved palette index, or -1 when transparency is off. Set eagerly for
  /// a supplied table, on the first RGB/RGBA frame for a derived one.
  int _transparentIndex = -1;

  /// The palette index that decodes to a hole, or null when transparency is off
  /// or a derived table has not been built yet.
  ///
  /// An [addIndexedFrame] caller places holes by writing this value into its
  /// index buffer; the RGB paths do it from alpha automatically.
  int? get transparentIndex =>
      _transparentIndex >= 0 ? _transparentIndex : null;

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
  bool _closing = false;
  bool _addingStream = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  late final Future<void> _sinkDone;
  (Object, StackTrace)? _failure;
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
  Future<void> get done => _sinkDone;

  void _recordFailure(Object error, StackTrace stackTrace) {
    _failure ??= (error, stackTrace);
  }

  void _throwIfFailed() {
    final failure = _failure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }

  Future<void> _enqueueFrame(GifFrame frame, {bool fromStream = false}) {
    if (_closing || (_addingStream && !fromStream)) {
      return Future<void>.error(StateError(
        _closing ? 'the writer is closed' : 'the writer is consuming a stream',
      ));
    }
    final result = _tail.then((_) => _executeFrame(frame));
    // Keep the ordering chain usable after invalid input. Emission failures are
    // latched separately, so later operations release their inputs without I/O.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _executeFrame(GifFrame frame) async {
    _throwIfFailed();
    switch (frame.kind) {
      case GifFrameKind.indexed:
        await _addIndexedFrameNow(frame.pixels, delay: frame.delay);
      case GifFrameKind.rgb:
        await _addRgbFrameNow(frame.pixels, delay: frame.delay);
      case GifFrameKind.rgba:
        await _addRgbaFrameNow(
          frame.pixels,
          background: frame.background,
          delay: frame.delay,
        );
    }
    _throwIfFailed();
  }

  /// Appends a frame of palette indices, one byte per pixel.
  ///
  /// [indices] must be exactly `width * height` long and every byte must be a
  /// valid index into the colour table — this is checked, because an out-of-range
  /// index produces a file that decodes to the wrong colours rather than failing.
  ///
  /// [delay] is rounded to hundredths of a second and clamped to GIF's 16-bit
  /// field. Viewers may impose their own minimum playback delay.
  Future<void> addIndexedFrame(
    Uint8List indices, {
    Duration delay = Duration.zero,
  }) => _enqueueFrame(GifFrame(indices: indices, delay: delay));

  Future<void> _addIndexedFrameNow(
    Uint8List indices, {
    required Duration delay,
  }) async {
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
  }) => _enqueueFrame(GifFrame.rgb(rgb, delay: delay));

  Future<void> _addRgbFrameNow(
    Uint8List rgb, {
    required Duration delay,
  }) async {
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
    // An RGB frame is fully opaque, so every pixel is a candidate colour.
    _ensureColorsFromRgb(rgb);
    final indices = _map(rgb);
    // No range check: these indices came from our own mapper, which cannot
    // produce one outside the table. The check exists for bytes a caller
    // supplied, and it is a whole extra pass over every pixel.
    await _writeIndexed(indices: indices, delay: delay, validate: false);
  }

  /// Appends a frame of RGBA pixels, four bytes each, mapped as [addRgbFrame]
  /// does after alpha is resolved.
  ///
  /// [background] is **optional once `transparency:` was given** to the
  /// constructor, and how alpha is handled depends on both:
  ///
  /// | | `background` given | `background` null |
  /// |---|---|---|
  /// | transparency off | composited over it | alpha ignored, RGB used as-is |
  /// | transparency on | alpha below the threshold becomes a hole, else composited over it | alpha below the threshold becomes a hole, else RGB used as-is |
  ///
  /// GIF has no partial alpha, so this thresholds rather than blends: a
  /// background, when supplied, only refines the colour of a pixel that is
  /// *drawn*. **Without transparency and without a background there is nowhere
  /// for alpha to go**, so a semi-transparent pixel is written at full opacity —
  /// pass a `background`, or turn on `transparency:`, if that is not what you
  /// want.
  Future<void> addRgbaFrame(
    Uint8List rgba, {
    int? background,
    Duration delay = Duration.zero,
  }) => _enqueueFrame(GifFrame.rgba(rgba, background: background, delay: delay));

  Future<void> _addRgbaFrameNow(
    Uint8List rgba, {
    required int? background,
    required Duration delay,
  }) async {
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
    _ensureColorsFromRgb(rgb, rgba: rgba);
    final indices = _map(rgb, rgba: rgba);
    await _writeIndexed(indices: indices, delay: delay, validate: false);
  }

  /// Resolves RGBA to opaque RGB in the scratch buffer.
  ///
  /// With a [background], a semi-transparent pixel is flattened onto it; without
  /// one, the pixel keeps its own colour. With transparency enabled, the mapper
  /// uses the original alpha channel to resolve holes during dithering.
  Uint8List _composite({required Uint8List rgba, required int? background}) {
    final rgb = _rgbScratch ??= Uint8List(_width * _height * 3);
    if (background == null) {
      // Keep the supplied colour; the mapper applies transparency when enabled.
      for (var i = 0, p = 0; p < rgb.length; i += 4, p += 3) {
        rgb[p] = rgba[i];
        rgb[p + 1] = rgba[i + 1];
        rgb[p + 2] = rgba[i + 2];
      }
      return rgb;
    }
    final br = (background >> 16) & 0xFF;
    final bg = (background >> 8) & 0xFF;
    final bb = background & 0xFF;
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

  /// Derives the global table from the first frame if none was supplied.
  ///
  /// [rgb] is the opaque, composited buffer. When transparency is on, only the
  /// pixels that will actually be shown feed the quantiser — passing [rgba] lets
  /// the alpha channel select them — and one slot is reserved for the hole. With
  /// no transparency this is the plain 256-colour derivation.
  void _ensureColorsFromRgb(Uint8List rgb, {Uint8List? rgba}) {
    if (_colors != null) return;
    if (_transparency == null) {
      _colors = GifColorTable.quantize(rgb, quantizer: _quantizer);
      return;
    }
    final source = rgba == null ? rgb : _opaquePixels(rgb: rgb, rgba: rgba);
    final real = GifColorTable.quantize(
      source,
      maxColors: 255,
      quantizer: _quantizer,
    );
    _colors = _withTransparentSlot(real);
    _transparentIndex = _colors!.length - 1;
  }

  /// The RGB of the pixels at or above the alpha threshold, packed three bytes
  /// each — the colours a transparent frame will actually show.
  ///
  /// A transient buffer, built once when the table is derived, like Wu's
  /// histogram; it does not touch the flat held-memory figure. Falls back to the
  /// whole frame when nothing is opaque, so an all-transparent first frame still
  /// yields a valid table rather than an empty quantiser input.
  Uint8List _opaquePixels({required Uint8List rgb, required Uint8List rgba}) {
    final threshold = _transparency!.alphaThreshold;
    var opaque = 0;
    for (var a = 3; a < rgba.length; a += 4) {
      if (rgba[a] >= threshold) opaque++;
    }
    if (opaque == 0 || opaque == rgba.length ~/ 4) return rgb;
    final out = Uint8List(opaque * 3);
    for (var s = 0, a = 3, d = 0; a < rgba.length; s += 3, a += 4) {
      if (rgba[a] >= threshold) {
        out[d] = rgb[s];
        out[d + 1] = rgb[s + 1];
        out[d + 2] = rgb[s + 2];
        d += 3;
      }
    }
    return out;
  }

  /// Refuses a palette with no room for the reserved transparent slot.
  static void _checkTransparentPalette(GifColorTable realColors) {
    if (realColors.length > 255) {
      throw ArgumentError.value(
        realColors.length,
        'colors',
        'a transparent GIF needs a free palette slot; pass at most 255 colours',
      );
    }
  }

  /// Returns [realColors] with the reserved transparent slot appended.
  GifColorTable _withTransparentSlot(GifColorTable realColors) {
    _checkTransparentPalette(realColors);
    return GifColorTable.packed(<int>[
      for (var i = 0; i < realColors.length; i++) realColors[i],
      _transparentColor,
    ]);
  }

  Uint8List _map(Uint8List rgb, {Uint8List? rgba}) {
    // The reserved slot is excluded from mapping, so no opaque pixel is ever
    // mapped onto the transparent index — only alpha-aware mapping places it.
    final mapper =
        _mapper ??= ColorMapper(
          _colors!,
          mapCount: _transparentIndex >= 0 ? _transparentIndex : null,
        );
    final runner =
        _runner ??= DitherRunner(
          dither: _dither,
          mapper: mapper,
          width: _width,
        );
    final out = _scratch ??= Uint8List(_width * _height);
    runner.mapRgb(
      rgb: rgb,
      out: out,
      rgba: _transparency == null ? null : rgba,
      alphaThreshold: _transparency?.alphaThreshold ?? 128,
      transparentIndex: _transparentIndex,
    );
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

    try {
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
      // The queue owns the writer until the destination accepts this frame.
      // Await once per frame, keeping sub-block writes batched.
      _out.flush();
      await _onFlush?.call();
    } catch (error, stackTrace) {
      _recordFailure(error, stackTrace);
      _throwIfFailed();
    }
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
    // GIF stores whole hundredths of a second. Round to the nearest value
    // rather than systematically shortening fractional delays.
    final centiseconds = (delay.inMicroseconds / 10000).round().clamp(
      0,
      0xFFFF,
    );
    // Filled in place: the two bytes that vary are the delay, and the rest of
    // this block is the same for every frame of every animation.
    _control[4] = centiseconds & 0xFF;
    _control[5] = (centiseconds >> 8) & 0xFF;
    if (_transparency != null) {
      // Packed field: disposal in bits 2-4, transparent-colour flag in bit 0.
      // Both constant across frames, but written here rather than once so the
      // one place that assembles this block holds the whole truth of it.
      _control[3] = (_transparency.disposal.bits << 2) | 0x01;
      _control[6] = _transparentIndex;
    }
    _out.add(_control);
  }

  void _writeImageDescriptor() {
    _descriptor[0] = 0x2C;
    // Left and top stay zero; frame diffing is not implemented, so each frame
    // occupies the whole logical screen.
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
  /// Stops accepting new frames immediately and drains those already queued.
  /// Repeated calls return the same future, including the same failure. Even
  /// after an output failure, closing attempts to release the underlying sink.
  ///
  /// A GIF with no frames is still written, header and all: a zero-frame file is
  /// a valid, empty animation, and throwing here would strand a caller whose
  /// stream happened to be empty.
  @override
  Future<void> close() {
    final closing = _closeFuture;
    if (closing != null) return closing;
    if (_addingStream) {
      return Future<void>.error(StateError('the writer is consuming a stream'));
    }
    _closing = true;
    return _closeFuture = _finish();
  }

  Future<void> _finish() async {
    await _tail;
    try {
      _throwIfFailed();
      if (!_headerWritten) {
        _writeHeader();
        _headerWritten = true;
      }
      _out.addByte(0x3B);
      _out.flush();
      await _onFlush?.call();
    } catch (error, stackTrace) {
      _recordFailure(error, stackTrace);
    }
    try {
      // Close without reflushing: a failed handover must never be retried.
      await _out.close();
      await _sinkDone;
    } catch (error, stackTrace) {
      _recordFailure(error, stackTrace);
    }
    _throwIfFailed();
  }

  /// Consumes a stream of frames, so `frames.pipe(writer)` works.
  /// Await consumption before another stream, a direct frame write, or [close].
  /// On a source error the caller remains responsible for closing the writer.
  @override
  Future<void> addStream(Stream<GifFrame> stream) async {
    if (_closing || _addingStream) {
      throw StateError(
        _closing ? 'the writer is closed' : 'the writer is consuming a stream',
      );
    }
    _throwIfFailed();
    _addingStream = true;
    try {
      await for (final frame in stream) {
        await _enqueueFrame(frame, fromStream: true);
      }
    } finally {
      _addingStream = false;
    }
  }
}
