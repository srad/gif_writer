/// A streaming GIF encoder.
///
/// Frames are compressed and written to a sink as they arrive, so memory stays
/// flat however long the animation runs. The usual approach — and the only other
/// one available in Dart — builds the whole file in memory and hands it over at
/// the end, which a long capture on a phone cannot afford.
///
/// You bring the colour table. Give it **palette indices** and the round trip is
/// byte-exact; give it **RGB** and it is mapped onto your table, dithering the
/// colours the table cannot hold.
///
/// ```dart
/// final gif = GifWriter.toFile(
///   'out.gif',
///   width: 64,
///   height: 64,
///   colors: GifColorTable.packed(<int>[0x000000, 0xFF5500, 0xFFFFFF]),
/// );
///
/// // One byte per pixel: an index into the table above. Nothing approximates it.
/// await gif.addIndexedFrame(indices, delay: const Duration(milliseconds: 50));
///
/// // Or three bytes per pixel, mapped and dithered onto the same table.
/// await gif.addRgbFrame(rgb, delay: const Duration(milliseconds: 50));
///
/// await gif.close();
/// ```
///
/// The dither defaults to [GifDither.blueNoise] rather than Floyd–Steinberg,
/// which is deliberate: error diffusion makes regions that never changed decode
/// differently from frame to frame. See [GifDither].
library;

export 'src/color_table.dart' show GifColorTable;
export 'src/dither.dart' show GifDither;
export 'src/frame.dart' show GifFrame, GifFrameKind;
export 'src/writer.dart' show GifRepeat, GifWriter;
