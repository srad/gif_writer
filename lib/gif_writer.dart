/// A streaming GIF encoder.
///
/// Frames are compressed and written to a sink as they arrive, so memory stays
/// flat however long the animation runs. The usual approach — and the only other
/// one available in Dart — builds the whole file in memory and hands it over at
/// the end, which a long capture on a phone cannot afford.
///
/// ```dart
/// final gif = GifWriter.toFile(
///   'out.gif',
///   width: 64,
///   height: 64,
///   colors: GifColorTable.packed(<int>[0x000000, 0xFFFFFF]),
/// );
/// for (final frame in frames) {
///   await gif.addIndexedFrame(frame, delay: const Duration(milliseconds: 50));
/// }
/// await gif.close();
/// ```
library;

export 'src/color_table.dart' show GifColorTable;
export 'src/frame.dart' show GifFrame;
export 'src/writer.dart' show GifRepeat, GifWriter;
