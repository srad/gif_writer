/// A streaming GIF encoder.
///
/// Awaited frames are compressed and written to a sink as they arrive, so memory
/// stays bounded as the animation grows, provided the sink also drains its output.
/// Input buffers must remain unchanged until their frame futures complete;
/// overlapping writes are ordered but retain all waiting inputs.
///
/// Bring a colour table, or let it derive one. Give it **palette indices** and
/// the round trip is byte-exact; give it **RGB** and it is mapped onto a table —
/// yours, or one quantised from the first frame — dithering the colours the table
/// cannot hold.
///
/// ```dart
/// final gif = GifWriter.toFile(
///   'out.gif',
///   width: 64,
///   height: 64,
///   colors: GifColorTable.packed(<int>[0x000000, 0xFF5500, 0xFFFFFF]),
/// );
///
/// try {
///   // One byte per pixel: an index into the table above. Nothing approximates it.
///   await gif.addIndexedFrame(indices, delay: const Duration(milliseconds: 50));
///
///   // Or three bytes per pixel, mapped and dithered onto the same table.
///   await gif.addRgbFrame(rgb, delay: const Duration(milliseconds: 50));
///
/// } finally {
///   await gif.close();
/// }
/// ```
///
/// The dither defaults to [GifDither.blueNoise] rather than Floyd–Steinberg,
/// which is deliberate: error diffusion makes regions that never changed decode
/// differently from frame to frame. See [GifDither].
library;

export 'src/color_table.dart' show GifColorTable;
export 'src/dither.dart' show GifDither;
export 'src/frame.dart' show GifFrame, GifFrameKind;
export 'src/quantizer.dart' show GifQuantizer;
export 'src/transparency.dart' show GifDisposal, GifTransparency;
export 'src/writer.dart' show GifRepeat, GifWriter;
