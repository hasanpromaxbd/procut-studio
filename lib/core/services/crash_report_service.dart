/// Crash persistence and diagnostics export.
///
/// The log ring buffer dies with the process, which is exactly when it was
/// needed. This service writes every uncaught error to disk *at the moment it
/// happens* — synchronously enough to survive the process being killed a
/// breath later — together with the last stretch of the ring buffer as
/// breadcrumbs.
///
/// There is deliberately no network here. Nothing leaves the device unless
/// the user shares a report themselves; a video editor has no business
/// phoning home, and the diagnostics screen says exactly what a report
/// contains before offering the share button.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../logging/app_logger.dart';

class CrashReport {
  const CrashReport({
    required this.id,
    required this.at,
    required this.error,
    required this.stackTrace,
    required this.breadcrumbs,
    required this.fatal,
  });

  final String id;
  final DateTime at;
  final String error;
  final String stackTrace;

  /// The tail of the log ring buffer at the moment of the crash — what the
  /// app was doing, not just where it died.
  final List<String> breadcrumbs;

  /// True for errors that would have crashed the process; false for caught
  /// zone errors the app survived.
  final bool fatal;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toIso8601String(),
    'error': error,
    'stack': stackTrace,
    'breadcrumbs': breadcrumbs,
    'fatal': fatal,
  };

  static CrashReport? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null) return null;
    return CrashReport(
      id: id,
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime(2000),
      error: json['error'] as String? ?? 'unknown',
      stackTrace: json['stack'] as String? ?? '',
      breadcrumbs:
          (json['breadcrumbs'] as List?)?.cast<String>() ?? const [],
      fatal: json['fatal'] as bool? ?? true,
    );
  }
}

class CrashReportService {
  CrashReportService({required Directory directory}) : _dir = directory;

  static const _log = Log('CrashReport');

  /// Keep the newest few and delete the rest: crash files that pile up
  /// forever are their own kind of leak.
  static const int _keep = 20;

  final Directory _dir;

  /// Where the last session's crash count is surfaced from, set by [init].
  int newSinceLastCheck = 0;

  Future<void> init() async {
    try {
      if (!_dir.existsSync()) _dir.createSync(recursive: true);
      await _prune();
    } catch (e) {
      // Never let diagnostics take the app down — the irony would be total.
      _log.w('crash store unavailable', error: e);
    }
  }

  /// Records one error. Synchronous file write on purpose: this runs while
  /// the process may be dying, and an awaited write may never happen.
  void record({
    required Object error,
    required StackTrace? stackTrace,
    required bool fatal,
  }) {
    try {
      final now = DateTime.now();
      final id = 'crash_${now.millisecondsSinceEpoch}';
      final report = CrashReport(
        id: id,
        at: now,
        error: '$error',
        stackTrace: '${stackTrace ?? StackTrace.current}',
        breadcrumbs: [
          for (final record in AppLogger.ringBuffer.records.take(60))
            record.toString(),
        ],
        fatal: fatal,
      );
      File(p.join(_dir.path, '$id.json'))
          .writeAsStringSync(jsonEncode(report.toJson()), flush: true);
    } catch (_) {
      // Swallowed: a failing crash reporter must never become the crash.
    }
  }

  Future<List<CrashReport>> list() async {
    if (!_dir.existsSync()) return const [];
    final reports = <CrashReport>[];
    for (final entity in _dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final report = CrashReport.fromJson(json);
        if (report != null) reports.add(report);
      } catch (_) {
        // A truncated file from a mid-write kill; not worth surfacing.
      }
    }
    reports.sort((a, b) => b.at.compareTo(a.at));
    return reports;
  }

  Future<void> clear() async {
    if (!_dir.existsSync()) return;
    for (final entity in _dir.listSync()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Builds one shareable text file from every stored report plus the current
  /// session's log tail. Returns its path.
  Future<String> exportDiagnostics({
    required String appVersion,
    required File target,
  }) async {
    final reports = await list();
    final buffer = StringBuffer()
      ..writeln('ProCut Studio diagnostics')
      ..writeln('version: $appVersion')
      ..writeln('generated: ${DateTime.now().toIso8601String()}')
      ..writeln('platform: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln()
      ..writeln('── current session log ──');
    for (final record in AppLogger.ringBuffer.records) {
      buffer.writeln(record);
    }
    buffer
      ..writeln()
      ..writeln('── stored crash reports (${reports.length}) ──');
    for (final report in reports) {
      buffer
        ..writeln()
        ..writeln('[${report.at.toIso8601String()}] '
            '${report.fatal ? 'FATAL' : 'caught'}')
        ..writeln(report.error)
        ..writeln(report.stackTrace)
        ..writeln('breadcrumbs:');
      for (final crumb in report.breadcrumbs) {
        buffer.writeln('  $crumb');
      }
    }
    await target.writeAsString(buffer.toString());
    return target.path;
  }

  Future<void> _prune() async {
    final files = _dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final file in files.skip(_keep)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }
}
