import 'dart:typed_data';

/// One frame, for the [Stream] form of the API.
///
/// A record rather than a class so a caller can build one inline without an
/// import ceremony; see `GifWriter.addStream`.
class GifFrame {
  const GifFrame({required this.indices, this.delay = Duration.zero});

  /// One byte per pixel, `width * height` of them, each an index into the
  /// writer's colour table.
  final Uint8List indices;

  /// How long this frame is shown.
  ///
  /// GIF stores hundredths of a second, so anything finer is rounded. **Many
  /// viewers also refuse delays below two hundredths**, silently substituting
  /// ten — so a "60 fps" GIF is a fiction the format cannot express and the
  /// browser will not honour. See `GifWriter.addIndexedFrame`.
  final Duration delay;
}
