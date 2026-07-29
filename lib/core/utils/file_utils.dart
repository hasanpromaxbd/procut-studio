import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants/app_constants.dart';

enum MediaKind { video, audio, image, unknown }

abstract final class FileUtils {
  static String extensionOf(String path) {
    final ext = p.extension(path);
    return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
  }

  static String baseNameWithoutExtension(String path) =>
      p.basenameWithoutExtension(path);

  static MediaKind kindOf(String path) {
    final ext = extensionOf(path);
    if (AppConstants.supportedVideoExtensions.contains(ext)) {
      return MediaKind.video;
    }
    if (AppConstants.supportedAudioExtensions.contains(ext)) {
      return MediaKind.audio;
    }
    if (AppConstants.supportedImageExtensions.contains(ext)) {
      return MediaKind.image;
    }
    return MediaKind.unknown;
  }

  static bool isSupported(String path) => kindOf(path) != MediaKind.unknown;

  static Future<bool> exists(String path) => File(path).exists();

  static Future<int> sizeOf(String path) async {
    final file = File(path);
    return await file.exists() ? file.length() : 0;
  }

  /// Copies [source] into [targetDir], never overwriting: a name collision
  /// gets a numeric suffix.
  static Future<File> copyInto(File source, Directory targetDir) async {
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final name = p.basenameWithoutExtension(source.path);
    final ext = p.extension(source.path);
    var target = File(p.join(targetDir.path, '$name$ext'));
    var n = 1;
    while (await target.exists()) {
      target = File(p.join(targetDir.path, '$name($n)$ext'));
      n++;
    }
    return source.copy(target.path);
  }

  /// Deletes without throwing — used on cleanup paths where a missing file is
  /// the desired end state anyway.
  static Future<void> deleteQuietly(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Intentionally ignored.
    }
  }

  static Future<void> deleteDirQuietly(Directory? dir) async {
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Intentionally ignored.
    }
  }

  /// Writes via a temp file then renames, so a crash mid-write cannot leave a
  /// truncated project file behind. rename() is atomic within a filesystem.
  static Future<void> writeAtomically(File target, String contents) async {
    final dir = target.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(target.path);
  }

  const FileUtils._();
}
