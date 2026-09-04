/// Measures this package against `package:image`, the only other GIF encoder
/// for Dart, on identical input.
///
/// **Fairness matters more than a flattering number.** Both encoders are given
/// frames that already carry a palette, so neither quantises — `image` would
/// otherwise be paying for NeuQuant that this package does not implement, and
/// the comparison would say nothing. Both outputs are decoded and checked
/// pixel-for-pixel before a single timing is printed.
///
/// Run it yourself: `dart run tool/compare.dart`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';
import 'package:image/image.dart' as img;

import 'sample_image.dart';

/// Counts what an encoder hands over, and the largest single handover.
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

/// One encoder's result for one workload.
typedef Run = ({double ms, int bytes, int peak, int adds});

const int size = 256;
const int frames = 60;
const int trials = 9;

Future<void> main() async {
  print('$frames frames of $size x $size, neither encoder quantising');
  print('median of $trials interleaved trials, range alongside\n');
  print(
    '${'workload'.padRight(22)}${'rate (median)'.padLeft(16)}'
    '${'range'.padLeft(20)}${'held'.padLeft(10)}'
    '${'writes'.padLeft(8)}${'output'.padLeft(11)}',
  );

  // Two workloads at two palette sizes. Noise is LZW's worst case and the
  // fairest stress test of the compressor itself; the photographic image is
  // what content actually looks like, and the two disagree enough that quoting
  // only one of them would be a choice rather than a measurement.
  for (final colours in <int>[32, 256]) {
    for (final workload in <String>['noise', 'photo']) {
      final frame =
          workload == 'noise'
              ? SampleImage.noise(side: size, colours: colours)
              : SampleImage.photo(side: size, colours: colours);
      await compare(
        label: '$workload · $colours colours',
        frame: frame,
        colours: colours,
      );
    }
  }
}

Future<void> compare({
  required String label,
  required Uint8List frame,
  required int colours,
}) async {
  final packed = <int>[
    for (var i = 0; i < colours; i++) (i * 255 ~/ (colours - 1)) * 0x010101,
  ];

  // ---- gif_writer -----------------------------------------------------------
  final table = GifColorTable.packed(packed);
  Future<Run> runOurs() async {
    final sink = CountingSink();
    final gif = GifWriter(sink, width: size, height: size, colors: table);
    final watch = Stopwatch()..start();
    for (var f = 0; f < frames; f++) {
      await gif.addIndexedFrame(frame);
    }
    await gif.close();
    watch.stop();
    return (
      ms: watch.elapsedMicroseconds / 1000,
      bytes: sink.bytes,
      peak: sink.peakHeld,
      adds: sink.adds,
    );
  }

  // ---- package:image --------------------------------------------------------
  // A palette image, so its encoder writes the indices as given rather than
  // quantising. Built once and reused, exactly as the frame above is.
  final palette = img.PaletteUint8(colours, 3);
  for (var i = 0; i < colours; i++) {
    palette.setRgb(
      i,
      (packed[i] >> 16) & 0xFF,
      (packed[i] >> 8) & 0xFF,
      packed[i] & 0xFF,
    );
  }
  final paletted = img.Image(
    width: size,
    height: size,
    numChannels: 1,
    palette: palette,
  );
  for (var i = 0; i < frame.length; i++) {
    paletted.data!.setPixelR(i % size, i ~/ size, frame[i]);
  }

  Run runTheirs() {
    final encoder = img.GifEncoder();
    final watch = Stopwatch()..start();
    for (var f = 0; f < frames; f++) {
      encoder.addFrame(paletted);
    }
    final out = encoder.finish();
    watch.stop();
    // Everything arrives in one piece at the end — that piece *is* the peak.
    return (
      ms: watch.elapsedMicroseconds / 1000,
      bytes: out?.length ?? 0,
      peak: out?.length ?? 0,
      adds: 1,
    );
  }

  // ---- fairness check -------------------------------------------------------
  //
  // **A timing comparison is worthless until both encoders are shown to be
  // doing the same job.** `package:image` quantises unless the frame already
  // carries a palette; if the setup above failed to give it one, it would be
  // paying for NeuQuant and losing a race it was never entered in. So both
  // outputs are decoded and checked against the input before anything is
  // printed — and this refuses to report timings rather than reporting bad
  // ones.
  {
    final builder = BytesBuilder();
    final gif = GifWriter(
      _CapturingSink(builder),
      width: size,
      height: size,
      colors: table,
    );
    await gif.addIndexedFrame(frame);
    await gif.close();

    final mine = img.GifDecoder().decode(builder.toBytes())!.frames.first;
    final encoder = img.GifEncoder()..addFrame(paletted);
    final other = img.GifDecoder().decode(encoder.finish()!)!.frames.first;

    var mineWrong = 0;
    var otherWrong = 0;
    for (var i = 0; i < frame.length; i++) {
      final want = packed[frame[i]];
      int rgb(img.Image f) {
        final p = f.getPixel(i % size, i ~/ size);
        return (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
      }

      if (rgb(mine) != want) mineWrong++;
      if (rgb(other) != want) otherWrong++;
    }
    if (mineWrong != 0 || otherWrong != 0) {
      print(
        '$label: NOT COMPARABLE — gif_writer $mineWrong wrong pixels, '
        'package:image $otherWrong wrong pixels. Timings suppressed.',
      );
      return;
    }
  }

  // Warm both before timing either, or whichever runs first looks slowest.
  await runOurs();
  runTheirs();

  // **Median of an odd number of trials, with the spread reported.**
  //
  // Not best-of-N, which an earlier version of this tool used: the minimum is a
  // measurement of the luckiest moment the machine had, and it silently
  // flatters whichever encoder happens to be scheduled better. The median is
  // what a user would actually see, and printing the range beside it is what
  // stops a 3% difference being read as a result when the spread is 5%.
  //
  // The two are interleaved rather than run in blocks, so a thermal drift or a
  // background process partway through hits both equally.
  final oursRuns = <Run>[];
  final theirsRuns = <Run>[];
  for (var i = 0; i < trials; i++) {
    oursRuns.add(await runOurs());
    theirsRuns.add(runTheirs());
  }

  (double median, double low, double high) spread(List<Run> runs) {
    final times = runs.map((r) => r.ms).toList()..sort();
    return (times[times.length ~/ 2], times.first, times.last);
  }

  final pixels = size * size * frames;
  double rate(double ms) => pixels / (ms * 1000);
  String mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';

  final oursTime = spread(oursRuns);
  final theirsTime = spread(theirsRuns);

  print('');
  for (final (name, r, t) in <(String, Run, (double, double, double))>[
    ('  gif_writer', oursRuns.first, oursTime),
    ('  package:image', theirsRuns.first, theirsTime),
  ]) {
    final (median, low, high) = t;
    print(
      '${(name == '  gif_writer' ? label : '').padRight(22)}'
      '${'${rate(median).toStringAsFixed(1)} Mpx/s'.padLeft(16)}'
      '${'${rate(high).toStringAsFixed(1)} - '
          '${rate(low).toStringAsFixed(1)}'.padLeft(20)}'
      '${mb(r.peak).padLeft(10)}'
      '${r.adds.toString().padLeft(8)}'
      '${mb(r.bytes).padLeft(11)}   ${name.trim()}',
    );
  }

  // Stated rather than left to the reader: a difference smaller than the wider
  // of the two spreads is not a result, and saying so is the difference between
  // a benchmark and an advertisement.
  final gap = rate(oursTime.$1) - rate(theirsTime.$1);
  final spreadWidth = [
    rate(oursTime.$2) - rate(oursTime.$3),
    rate(theirsTime.$2) - rate(theirsTime.$3),
  ].reduce((a, b) => a > b ? a : b);
  final verdict =
      gap.abs() <= spreadWidth
          ? 'level — the ${gap.abs().toStringAsFixed(1)} Mpx/s gap is inside the '
              '${spreadWidth.toStringAsFixed(1)} Mpx/s spread'
          : '${gap > 0 ? 'gif_writer' : 'package:image'} faster by '
              '${(gap.abs() / rate(theirsTime.$1) * 100).toStringAsFixed(0)}%, '
              'outside the ${spreadWidth.toStringAsFixed(1)} Mpx/s spread';

  // Compression, which is the other half of the story: a faster encoder that
  // wrote a bigger file has not necessarily won.
  final ourBytes = oursRuns.first.bytes;
  final theirBytes = theirsRuns.first.bytes;
  final smaller = (theirBytes - ourBytes) / theirBytes * 100;
  final sizeVerdict =
      smaller.abs() < 0.05
          ? 'output identical in size'
          : 'output ${smaller > 0 ? 'smaller' : 'larger'} by '
              '${smaller.abs().toStringAsFixed(1)}%';
  print('${' ' * 22}$verdict; $sizeVerdict');
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
