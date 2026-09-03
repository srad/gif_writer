import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;

/// Measures this package against `package:image`, the only other GIF encoder
/// for Dart, on identical input.
///
/// **Fairness matters more than a flattering number.** Both encoders are given
/// frames that already carry a palette, so neither quantises — `image` would
/// otherwise be paying for NeuQuant that this package does not implement, and
/// the comparison would say nothing. Run it yourself:
/// `dart run tool/compare.dart`.
final class CountingSink implements StreamSink<List<int>> {
  int bytes = 0;
  int adds = 0;
  int peakHeld = 0;

  @override
  void add(List<int> data) {
    bytes += data.length;
    adds++;
    // What the encoder handed over in one go. For a streaming encoder this is
    // the staging buffer; for a buffering one it is the finished file.
    if (data.length > peakHeld) peakHeld = data.length;
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future<void>.value();
}

Future<void> main() async {
  const size = 256;
  const frames = 60;
  const colours = 32;

  final random = Random(7);
  final noise = Uint8List(size * size);
  for (var i = 0; i < noise.length; i++) {
    noise[i] = random.nextInt(colours);
  }

  final packed = <int>[
    for (var i = 0; i < colours; i++) (i * 255 ~/ (colours - 1)) * 0x010101,
  ];

  // ---- gif_writer -----------------------------------------------------------
  final table = GifColorTable.packed(packed);
  Future<(double ms, int bytes, int peak, int adds)> runOurs() async {
    final sink = CountingSink();
    final gif = GifWriter(sink, width: size, height: size, colors: table);
    final watch = Stopwatch()..start();
    for (var f = 0; f < frames; f++) {
      await gif.addIndexedFrame(noise);
    }
    await gif.close();
    watch.stop();
    return (
      watch.elapsedMicroseconds / 1000,
      sink.bytes,
      sink.peakHeld,
      sink.adds,
    );
  }

  // ---- package:image --------------------------------------------------------
  // A palette image, so its encoder writes the indices as given rather than
  // quantising. Built once and reused, exactly as the frame above is.
  final palette = img.PaletteUint8(colours, 3);
  for (var i = 0; i < colours; i++) {
    palette.setRgb(i, (packed[i] >> 16) & 0xFF, (packed[i] >> 8) & 0xFF,
        packed[i] & 0xFF);
  }
  final paletted = img.Image(
    width: size,
    height: size,
    numChannels: 1,
    palette: palette,
  );
  for (var i = 0; i < noise.length; i++) {
    paletted.data!.setPixelR(i % size, i ~/ size, noise[i]);
  }

  (double ms, int bytes, int peak, int adds) runTheirs() {
    final encoder = img.GifEncoder();
    final watch = Stopwatch()..start();
    for (var f = 0; f < frames; f++) {
      encoder.addFrame(paletted);
    }
    final out = encoder.finish();
    watch.stop();
    // Everything arrives in one piece at the end — that piece *is* the peak.
    return (watch.elapsedMicroseconds / 1000, out?.length ?? 0, out?.length ?? 0, 1);
  }

  // ---- fairness check -------------------------------------------------------
  //
  // **A timing comparison is worthless until both encoders are shown to be doing
  // the same job.** `package:image` quantises unless the frame already carries a
  // palette; if the setup above failed to give it one, it would be paying for
  // NeuQuant and losing a race it was never entered in. So both outputs are
  // decoded and checked against the input before a single number is printed.
  {
    final sink = CountingSink();
    final builder = BytesBuilder();
    final capture = _CapturingSink(builder);
    final gif = GifWriter(capture, width: size, height: size, colors: table);
    await gif.addIndexedFrame(noise);
    await gif.close();
    sink.bytes = 0;

    final mine = img.GifDecoder().decode(builder.toBytes())!.frames.first;
    final encoder = img.GifEncoder()..addFrame(paletted);
    final other = img.GifDecoder().decode(encoder.finish()!)!.frames.first;

    var mineWrong = 0;
    var otherWrong = 0;
    for (var i = 0; i < noise.length; i++) {
      final want = packed[noise[i]];
      int rgb(img.Image f) {
        final p = f.getPixel(i % size, i ~/ size);
        return (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
      }

      if (rgb(mine) != want) mineWrong++;
      if (rgb(other) != want) otherWrong++;
    }
    print('fairness: gif_writer $mineWrong wrong pixels, '
        'package:image $otherWrong wrong pixels (of ${noise.length})');
    if (mineWrong != 0 || otherWrong != 0) {
      print('  ^ one of them is not encoding what it was given; the timings '
          'below would be meaningless. Stopping.');
      return;
    }
  }

  // Warm both before timing either, or whichever runs first looks slowest.
  await runOurs();
  runTheirs();

  // Best of five. A single sample on a desktop is mostly a measurement of what
  // else the machine was doing.
  (double, int, int, int) best(
    (double, int, int, int) a,
    (double, int, int, int) b,
  ) => a.$1 <= b.$1 ? a : b;

  var ours = await runOurs();
  var theirs = runTheirs();
  for (var i = 0; i < 4; i++) {
    ours = best(ours, await runOurs());
    theirs = best(theirs, runTheirs());
  }

  String mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  final pixels = size * size * frames;

  print('$frames frames of $size x $size, $colours colours, neither quantising\n');
  print('${'encoder'.padRight(16)}${'time'.padLeft(10)}'
      '${'rate'.padLeft(14)}${'largest handover'.padLeft(19)}'
      '${'writes'.padLeft(9)}${'output'.padLeft(11)}');
  for (final (name, r) in <(String, (double, int, int, int))>[
    ('gif_writer', ours),
    ('package:image', theirs),
  ]) {
    final (ms, bytes, peak, adds) = r;
    print('${name.padRight(16)}'
        '${'${ms.toStringAsFixed(0)} ms'.padLeft(10)}'
        '${'${(pixels / (ms * 1000)).toStringAsFixed(1)} Mpx/s'.padLeft(14)}'
        '${mb(peak).padLeft(19)}'
        '${adds.toString().padLeft(9)}'
        '${mb(bytes).padLeft(11)}');
  }
}

/// Captures bytes so the fairness check can decode what we wrote.
final class _CapturingSink implements StreamSink<List<int>> {
  _CapturingSink(this._builder);
  final BytesBuilder _builder;
  @override
  void add(List<int> data) => _builder.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future<void>.value();
}
