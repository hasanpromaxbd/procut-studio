/// Structured logging with pluggable sinks.
///
/// Deliberately dependency-free: a video editor emits a *lot* of log lines
/// (every FFmpeg frame callback), so the hot path must not allocate a formatter
/// object per call. Levels are compared with an int before any string work.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

enum LogLevel {
  verbose(0, 'V'),
  debug(1, 'D'),
  info(2, 'I'),
  warning(3, 'W'),
  error(4, 'E'),
  none(5, '-');

  const LogLevel(this.severity, this.tag);
  final int severity;
  final String tag;
}

@immutable
class LogRecord {
  const LogRecord({
    required this.level,
    required this.scope,
    required this.message,
    required this.timestamp,
    this.error,
    this.stackTrace,
    this.fields,
  });

  final LogLevel level;
  final String scope;
  final String message;
  final DateTime timestamp;
  final Object? error;
  final StackTrace? stackTrace;
  final Map<String, Object?>? fields;

  String format() {
    final b = StringBuffer()
      ..write('[${level.tag}] ')
      ..write(_hhmmss(timestamp))
      ..write(' $scope: ')
      ..write(message);
    if (fields != null && fields!.isNotEmpty) {
      b.write(' {');
      var first = true;
      fields!.forEach((k, v) {
        if (!first) b.write(', ');
        b.write('$k=$v');
        first = false;
      });
      b.write('}');
    }
    if (error != null) b.write('\n  error: $error');
    return b.toString();
  }

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

abstract interface class LogSink {
  void write(LogRecord record);
}

/// Prints to the platform console. Disabled in release by [AppLogger.minLevel].
class ConsoleLogSink implements LogSink {
  const ConsoleLogSink();

  @override
  void write(LogRecord record) {
    debugPrint(record.format());
    if (record.stackTrace != null && record.level == LogLevel.error) {
      debugPrintStack(stackTrace: record.stackTrace, maxFrames: 12);
    }
  }
}

/// Keeps the last N records so the in-app diagnostics screen (and a bug report
/// attached to a failed export) can show what happened without a USB cable.
class RingBufferLogSink implements LogSink {
  RingBufferLogSink({this.capacity = 500});

  final int capacity;
  final Queue<LogRecord> _records = Queue<LogRecord>();

  List<LogRecord> get records => List.unmodifiable(_records);

  @override
  void write(LogRecord record) {
    _records.addLast(record);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
  }

  void clear() => _records.clear();

  String dump({LogLevel minLevel = LogLevel.verbose}) => _records
      .where((r) => r.level.severity >= minLevel.severity)
      .map((r) => r.format())
      .join('\n');
}

class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  static final RingBufferLogSink ringBuffer = RingBufferLogSink();

  final List<LogSink> _sinks = <LogSink>[const ConsoleLogSink(), ringBuffer];

  /// Anything below this is discarded before the message is even built.
  LogLevel minLevel = kReleaseMode ? LogLevel.warning : LogLevel.debug;

  void addSink(LogSink sink) => _sinks.add(sink);
  void removeSink(LogSink sink) => _sinks.remove(sink);

  bool isEnabled(LogLevel level) => level.severity >= minLevel.severity;

  void log(
    LogLevel level,
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? fields,
  }) {
    if (!isEnabled(level)) return;
    final record = LogRecord(
      level: level,
      scope: scope,
      message: message,
      timestamp: DateTime.now(),
      error: error,
      stackTrace: stackTrace,
      fields: fields,
    );
    for (final sink in _sinks) {
      try {
        sink.write(record);
      } catch (_) {
        // A logging failure must never take down the app.
      }
    }
  }

  /// Times [body] and logs its duration — used to keep an eye on the edit
  /// operations that run on the UI isolate.
  Future<T> timed<T>(
    String scope,
    String label,
    Future<T> Function() body, {
    LogLevel level = LogLevel.debug,
  }) async {
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      log(level, scope, '$label took ${sw.elapsedMilliseconds}ms');
    }
  }
}

/// Scoped facade — one per class, so log lines are always attributable.
///
/// ```dart
/// final _log = Log('ExportEngine');
/// _log.i('starting', fields: {'preset': preset.id});
/// ```
class Log {
  const Log(this.scope);
  final String scope;

  void v(String m, {Map<String, Object?>? fields}) =>
      AppLogger.instance.log(LogLevel.verbose, scope, m, fields: fields);

  void d(String m, {Map<String, Object?>? fields}) =>
      AppLogger.instance.log(LogLevel.debug, scope, m, fields: fields);

  void i(String m, {Map<String, Object?>? fields}) =>
      AppLogger.instance.log(LogLevel.info, scope, m, fields: fields);

  void w(String m, {Object? error, Map<String, Object?>? fields}) =>
      AppLogger.instance
          .log(LogLevel.warning, scope, m, error: error, fields: fields);

  void e(
    String m, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? fields,
  }) =>
      AppLogger.instance.log(
        LogLevel.error,
        scope,
        m,
        error: error,
        stackTrace: stackTrace,
        fields: fields,
      );

  Future<T> timed<T>(String label, Future<T> Function() body) =>
      AppLogger.instance.timed(scope, label, body);
}

/// Installs global handlers so nothing dies silently.
void installGlobalErrorHandlers() {
  const log = Log('Uncaught');
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log.e(
      details.exceptionAsString(),
      error: details.exception,
      stackTrace: details.stack,
    );
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.e('Unhandled async error', error: error, stackTrace: stack);
    return true; // handled — do not crash the app over an isolate error
  };
}
