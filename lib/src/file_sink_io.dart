import 'dart:async';
import 'dart:io';

/// Opens [path] for writing, truncating anything already there.
StreamSink<List<int>> openFileSink(String path) => File(path).openWrite();

/// `IOSink.flush` is where back-pressure actually comes from: it completes when
/// the operating system has taken the bytes, so awaiting it once per frame stops
/// a fast producer queueing an unbounded amount inside the sink.
Future<void> Function()? flusherFor(StreamSink<List<int>> sink) =>
    sink is IOSink ? sink.flush : null;
