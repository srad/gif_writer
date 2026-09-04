/// How a transparent pixel's hole is filled once the next frame draws.
///
/// GIF stores this in three bits of each frame's Graphic Control Extension. The
/// values are the format's own — **not** the enum's declaration order — so
/// [bits] switches on the constant rather than returning `index`; reordering the
/// enum must not silently rewrite the wire format.
enum GifDisposal {
  /// No disposal specified. The decoder does as it likes; in practice the frame
  /// is left in place, like [doNotDispose].
  unspecified,

  /// Leave the frame in place. The next frame draws over it, so a transparent
  /// pixel shows whatever was already there.
  doNotDispose,

  /// Clear the frame's area to the background before the next draws, so a
  /// transparent pixel reveals the page behind the image. **The default**, and
  /// what makes a hole an actual hole.
  restoreBackground,

  /// Restore whatever was under the frame before it drew. Rarely wanted and
  /// poorly supported; here for completeness.
  restorePrevious;

  /// The 3-bit disposal code GIF writes, packed into bits 2–4 of the GCE's
  /// packed field by the writer.
  int get bits => switch (this) {
    GifDisposal.unspecified => 0,
    GifDisposal.doNotDispose => 1,
    GifDisposal.restoreBackground => 2,
    GifDisposal.restorePrevious => 3,
  };
}

/// Turns on GIF transparency for a `GifWriter`.
///
/// **GIF transparency is binary.** The format has no partial alpha: a pixel is
/// either fully opaque or fully absent. A frame names one palette index as
/// "transparent", and every pixel at that index is a hole. So this does not
/// blend — it *thresholds*: a pixel whose alpha is below [alphaThreshold] becomes
/// a hole, and everything at or above it is drawn opaque.
///
/// Passing this to `GifWriter`'s `transparency:` reserves one palette slot for
/// the transparent index (a supplied table must leave room; a derived one is
/// quantised to 255 colours), makes `addRgbaFrame`'s `background` optional, and
/// writes the transparent flag and [disposal] into every frame. Left unset,
/// nothing changes and `background` stays required — the 0.1.x behaviour.
///
/// A plain value object with `==`/`hashCode`, matching `GifDither`, `GifRepeat`
/// and `GifQuantizer`, so a caller can compare two or key a cache on one.
class GifTransparency {
  /// [alphaThreshold] is the alpha below which a pixel becomes a hole, 1 to 255.
  ///
  /// Validated rather than clamped, like the rest of this package: 0 would make
  /// nothing transparent and 256 everything, so both are almost certainly a
  /// mistake and are refused rather than silently encoded. The default of 128
  /// treats the lower half of the alpha range as transparent.
  GifTransparency({
    this.alphaThreshold = 128,
    this.disposal = GifDisposal.restoreBackground,
  }) {
    if (alphaThreshold < 1 || alphaThreshold > 255) {
      throw ArgumentError.value(
        alphaThreshold,
        'alphaThreshold',
        'must be 1 to 255',
      );
    }
  }

  /// The alpha below which a pixel is written as the transparent index.
  final int alphaThreshold;

  /// What a transparent pixel reveals once the next frame draws.
  final GifDisposal disposal;

  @override
  bool operator ==(Object other) =>
      other is GifTransparency &&
      other.alphaThreshold == alphaThreshold &&
      other.disposal == disposal;

  @override
  int get hashCode => Object.hash(alphaThreshold, disposal);

  @override
  String toString() =>
      'GifTransparency(alphaThreshold: $alphaThreshold, disposal: $disposal)';
}
