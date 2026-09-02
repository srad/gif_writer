import 'dart:async';

/// Opens a file for writing. Replaced by `file_sink_io.dart` wherever `dart:io`
/// exists; this is the version the web gets.
StreamSink<List<int>> openFileSink(String path) => throw UnsupportedError(
  'GifWriter.toFile needs dart:io. On the web, construct GifWriter with a sink '
  'of your own.',
);

/// How to apply back-pressure to [sink]. Nothing to do without `dart:io`.
Future<void> Function()? flusherFor(StreamSink<List<int>> sink) => null;
