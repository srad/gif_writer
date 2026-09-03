import 'dart:typed_data';

/// One frame, for the [Stream] form of the API.
///
/// Three shapes, matching the three `add…Frame` methods, so `frames.pipe(writer)`
/// accepts everything the direct calls do. A stream form that took only indexed
/// frames would read as an oversight rather than a decision.
class GifFrame {
  /// Palette indices, one byte per pixel. No mapping, byte-exact.
  ///
  /// The parameter stays named `indices` rather than becoming `pixels` with the
  /// rest: it is the one constructor 0.1.0 published, and renaming it would
  /// break every existing caller for a cosmetic gain.
  const GifFrame({required Uint8List indices, this.delay = Duration.zero})
    : pixels = indices,
      kind = GifFrameKind.indexed,
      background = 0;

  /// Three bytes per pixel, mapped to the writer's colour table with its dither.
  const GifFrame.rgb(this.pixels, {this.delay = Duration.zero})
    : kind = GifFrameKind.rgb,
      background = 0;

  /// Four bytes per pixel, composited over [background] and then mapped.
  ///
  /// [background] is **required**: GIF transparency is not implemented yet, and
  /// silently dropping alpha would give a wrong colour for every semi-transparent
  /// pixel rather than an obvious error.
  const GifFrame.rgba(
    this.pixels, {
    required this.background,
    this.delay = Duration.zero,
  }) : kind = GifFrameKind.rgba;

  /// The frame's bytes. What they mean depends on [kind] — palette indices, RGB
  /// triples, or RGBA quads.
  final Uint8List pixels;

  /// Which of the three shapes [pixels] holds.
  final GifFrameKind kind;

  /// The colour alpha is composited against, for [GifFrame.rgba]. Packed
  /// `0xRRGGBB`.
  final int background;

  /// How long this frame is shown.
  ///
  /// GIF stores hundredths of a second, so anything finer is rounded. **Many
  /// viewers also refuse delays below two hundredths**, silently substituting
  /// ten — so a "60 fps" GIF is a fiction the format cannot express and the
  /// browser will not honour. See `GifWriter.addIndexedFrame`.
  final Duration delay;

  /// The palette indices, for an [GifFrameKind.indexed] frame.
  ///
  /// Kept so code written against 0.1.x still reads naturally now that a frame
  /// can also hold RGB.
  Uint8List get indices => pixels;
}

/// What a [GifFrame]'s bytes are.
enum GifFrameKind {
  /// One byte per pixel, already an index into the colour table.
  indexed,

  /// Three bytes per pixel.
  rgb,

  /// Four bytes per pixel, the last being alpha.
  rgba,
}
