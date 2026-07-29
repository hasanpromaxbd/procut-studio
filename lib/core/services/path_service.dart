/// Owns every filesystem location the app uses.
///
/// Nothing else composes paths by hand — that is how you end up with exports
/// written into the cache directory and silently reaped by Android.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import '../logging/app_logger.dart';

class PathService {
  PathService();

  static const _log = Log('PathService');

  Directory? _documents;
  Directory? _cache;
  Directory? _temp;

  bool get isInitialised => _documents != null;

  Future<void> init() async {
    _documents = await getApplicationDocumentsDirectory();
    _cache = await getApplicationCacheDirectory();
    _temp = await getTemporaryDirectory();

    await Future.wait([
      _ensure(projectsDir),
      _ensure(mediaDir),
      _ensure(thumbnailsDir),
      _ensure(waveformsDir),
      _ensure(exportsDir),
      _ensure(backupsDir),
      _ensure(recordingsDir),
      _ensure(proxiesDir),
    ]);
    _log.i('initialised', fields: {'documents': _documents?.path});
  }

  Directory get _docs {
    final d = _documents;
    if (d == null) {
      throw StateError('PathService.init() must be awaited before use');
    }
    return d;
  }

  Directory get _cacheRoot {
    final d = _cache;
    if (d == null) {
      throw StateError('PathService.init() must be awaited before use');
    }
    return d;
  }

  // ── Durable: survives cache eviction, backed up on project export ──────
  Directory get projectsDir =>
      Directory(p.join(_docs.path, AppConstants.projectsDirName));

  /// Media copied into the app (recordings, trimmed sources we own).
  Directory get mediaDir =>
      Directory(p.join(_docs.path, AppConstants.mediaDirName));

  Directory get recordingsDir =>
      Directory(p.join(_docs.path, AppConstants.recordingsDirName));

  Directory get backupsDir =>
      Directory(p.join(_docs.path, AppConstants.backupsDirName));

  /// Finished renders. Kept in documents so Android will not reclaim a video
  /// the user has not yet shared.
  Directory get exportsDir =>
      Directory(p.join(_docs.path, AppConstants.exportsDirName));

  // ── Disposable: safe for the OS to reclaim, always regenerable ─────────
  Directory get thumbnailsDir =>
      Directory(p.join(_cacheRoot.path, AppConstants.thumbnailsDirName));

  Directory get waveformsDir =>
      Directory(p.join(_cacheRoot.path, AppConstants.waveformsDirName));

  Directory get proxiesDir =>
      Directory(p.join(_cacheRoot.path, AppConstants.proxiesDirName));

  Directory get tempDir => _temp ?? Directory.systemTemp;

  // ── File builders ─────────────────────────────────────────────────────
  File projectBackupFile(String projectId, int index) => File(
    p.join(backupsDir.path, '$projectId.$index.json'),
  );

  File thumbnailFile(String assetId, int timeMs, int width) =>
      File(p.join(thumbnailsDir.path, '${assetId}_${timeMs}_$width.jpg'));

  File waveformFile(String assetId) =>
      File(p.join(waveformsDir.path, '$assetId.wf'));

  File proxyFile(String assetId, int height) =>
      File(p.join(proxiesDir.path, '${assetId}_${height}p.mp4'));

  File recordingFile(String id, {String extension = 'm4a'}) =>
      File(p.join(recordingsDir.path, '$id.$extension'));

  /// Destination for a render. Names are sanitised and de-duplicated so two
  /// exports of "My Video" do not overwrite each other.
  Future<File> exportFile(String projectName, String extension) async {
    await _ensure(exportsDir);
    final safe = sanitiseFileName(projectName);
    final stamp = DateTime.now();
    final base = '${safe}_'
        '${stamp.year}${_two(stamp.month)}${_two(stamp.day)}_'
        '${_two(stamp.hour)}${_two(stamp.minute)}${_two(stamp.second)}';
    var candidate = File(p.join(exportsDir.path, '$base.$extension'));
    var n = 1;
    while (candidate.existsSync()) {
      candidate = File(p.join(exportsDir.path, '$base($n).$extension'));
      n++;
    }
    return candidate;
  }

  /// Scratch file inside the render workspace for a job. The whole directory
  /// is deleted when the job finishes, successfully or not.
  Directory renderWorkspace(String jobId) =>
      Directory(p.join(tempDir.path, 'render_$jobId'));

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Strips path separators and characters that break FAT32/exFAT SD cards.
  static String sanitiseFileName(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final trimmed = cleaned.isEmpty ? 'untitled' : cleaned;
    return trimmed.length > 64 ? trimmed.substring(0, 64).trim() : trimmed;
  }

  Future<Directory> _ensure(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Free bytes on the volume holding [dir]. Returns null when the platform
  /// will not tell us — callers must treat null as "unknown", not "full".
  Future<int?> freeSpaceBytes(Directory dir) async {
    try {
      final stat = await Process.run('df', ['-kP', dir.path]);
      if (stat.exitCode != 0) return null;
      final lines = (stat.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines[1].split(RegExp(r'\s+'));
      if (cols.length < 4) return null;
      return int.parse(cols[3]) * 1024;
    } catch (e) {
      _log.d('free space unavailable: $e');
      return null;
    }
  }

  /// Total bytes held by the regenerable caches.
  Future<int> cacheSizeBytes() async {
    var total = 0;
    for (final dir in [thumbnailsDir, waveformsDir, proxiesDir]) {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
    }
    return total;
  }

  Future<void> clearCaches() async {
    for (final dir in [thumbnailsDir, waveformsDir, proxiesDir]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await _ensure(dir);
    }
    _log.i('caches cleared');
  }

  /// Removes render workspaces left behind by a crash or a force-stop.
  Future<void> reapOrphanedWorkspaces() async {
    try {
      final root = tempDir;
      if (!await root.exists()) return;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory && p.basename(entity.path).startsWith('render_')) {
          await entity.delete(recursive: true);
          _log.d('reaped orphaned workspace ${entity.path}');
        }
      }
    } catch (e) {
      _log.w('workspace reap failed', error: e);
    }
  }
}
