import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gif_writer/gif_writer.dart';

/// Throughput of the encoder, measured rather than assumed.
///
/// Run with `dart run tool/benchmark.dart`. Compare candidates **inside one
/// run**: absolute figures move with the machine's thermal state and with what
/// else it is doing, so only ratios measured together mean anything.
///
/// A sink that counts and discards, so the disk is not being benchmarked.
final class CountingSink implements StreamSink<List<int>> {
  int bytes = 0;
  int adds = 0;

  @override
  void add(List<int> data) {
    bytes += data.length;
    adds++;
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
  const frames = 120;
  const colours = 32;

  final table = GifColorTable.packed(<int>[
    for (var i = 0; i < colours; i++)
      (i * 255 ~/ (colours - 1)) * 0x010101,
  ]);

  // Two workloads, because they stress opposite ends of LZW. Noise fills the
  // dictionary constantly and never gets long matches; a smooth gradient is
  // mostly long runs and exercises the fast path.
  final noise = Uint8List(size * size);
  final smooth = Uint8List(size * size);
  final random = Random(7);
  for (var i = 0; i < noise.length; i++) {
    noise[i] = random.nextInt(colours);
    smooth[i] = ((i ~/ size) * colours ~/ size).clamp(0, colours - 1);
  }

  Future<void> run(String name, Uint8List frame) async {
    // One untimed pass first: the JIT should be warm before the clock starts, or
    // the first candidate measured always looks slowest.
    for (var warm = 0; warm < 2; warm++) {
      final sink = CountingSink();
      final gif = GifWriter(
        sink,
        width: size,
        height: size,
        colors: table,
      );
      for (var f = 0; f < 8; f++) {
        await gif.addIndexedFrame(frame);
      }
      await gif.close();
    }

    final sink = CountingSink();
    final gif = GifWriter(sink, width: size, height: size, colors: table);
    final watch = Stopwatch()..start();
    for (var f = 0; f < frames; f++) {
      await gif.addIndexedFrame(frame);
    }
    await gif.close();
    watch.stop();

    final pixels = size * size * frames;
    final ms = watch.elapsedMicroseconds / 1000;
    final mpps = pixels / watch.elapsedMicroseconds;
    print(
      '${name.padRight(10)} '
      '${ms.toStringAsFixed(1).padLeft(8)} ms   '
      '${mpps.toStringAsFixed(1).padLeft(6)} Mpx/s   '
      '${(sink.bytes / 1024 / 1024).toStringAsFixed(2).padLeft(6)} MB out   '
      '${sink.adds} sink writes',
    );
  }

  print('$frames frames of $size x $size, $colours colours');
  print('${'workload'.padRight(10)} ${'time'.padLeft(11)}   '
      '${'rate'.padLeft(11)}   ${'size'.padLeft(9)}   writes');
  await run('noise', noise);
  await run('smooth', smooth);
}
