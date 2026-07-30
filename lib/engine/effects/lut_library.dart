/// The LUT shelf: bundled looks plus whatever `.cube` files the user brings.
///
/// FFmpeg's `lut3d` reads a file path, and Flutter assets are not files — so
/// the bundled LUTs are extracted to disk once, lazily, and imports land in
/// the same directory. One directory, one listing, no special cases after
/// this point.
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';

class LutEntry {
  const LutEntry({required this.name, required this.path, required this.bundled});

  /// Display name, from the file name: `teal_orange.cube` → "Teal orange".
  final String name;
  final String path;
  final bool bundled;
}

class LutLibrary {
  LutLibrary({required Directory directory}) : _dir = directory;

  static const _log = Log('LutLibrary');

  static const _bundledAssets = [
    'assets/luts/teal_orange.cube',
    'assets/luts/warm_film.cube',
    'assets/luts/moody_blue.cube',
    'assets/luts/bleach_bypass.cube',
  ];

  final Directory _dir;
  bool _extracted = false;

  /// Everything on the shelf, bundled first.
  Future<List<LutEntry>> list() async {
    await _ensureExtracted();
    if (!_dir.existsSync()) return const [];

    final bundledNames = {
      for (final asset in _bundledAssets) p.basename(asset),
    };
    final entries = <LutEntry>[];
    for (final entity in _dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.cube')) continue;
      final base = p.basename(entity.path);
      entries.add(
        LutEntry(
          name: _displayName(base),
          path: entity.path,
          bundled: bundledNames.contains(base),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.bundled != b.bundled) return a.bundled ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return entries;
  }

  /// Copies a user's `.cube` in, after checking it actually is one.
  ///
  /// The check is deliberately shallow — the header keyword and a sane size.
  /// FFmpeg is the real parser; this exists to catch "renamed a JPEG" at
  /// import time with a decent message instead of at export time with a
  /// cryptic one.
  Future<Result<LutEntry>> import(String sourcePath) async {
    try {
      final source = File(sourcePath);
      final head = await source
          .openRead(0, 64 * 1024)
          .transform(const SystemEncoding().decoder)
          .join();
      final sizeMatch = RegExp(r'LUT_3D_SIZE\s+(\d+)').firstMatch(head);
      final size = int.tryParse(sizeMatch?.group(1) ?? '');
      if (size == null || size < 2 || size > 256) {
        return const Result.err(
          UnsupportedMediaFailure(
            'That file does not look like a 3D .cube LUT.',
          ),
        );
      }

      await _dir.create(recursive: true);
      var base = p.basename(sourcePath);
      var target = File(p.join(_dir.path, base));
      // Never silently replace: two LUTs can share a filename and differ.
      var counter = 2;
      while (target.existsSync()) {
        base =
            '${p.basenameWithoutExtension(sourcePath)}_$counter.cube';
        target = File(p.join(_dir.path, base));
        counter++;
      }
      await source.copy(target.path);
      _log.i('lut imported', fields: {'name': base, 'size': size});
      return Result.ok(
        LutEntry(name: _displayName(base), path: target.path, bundled: false),
      );
    } catch (e, s) {
      return Result.err(
        StorageFailure('Could not import that LUT.', cause: e, stackTrace: s),
      );
    }
  }

  Future<void> _ensureExtracted() async {
    if (_extracted) return;
    try {
      await _dir.create(recursive: true);
      for (final asset in _bundledAssets) {
        final target = File(p.join(_dir.path, p.basename(asset)));
        if (target.existsSync()) continue;
        final data = await rootBundle.load(asset);
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
      _extracted = true;
    } catch (e) {
      // A failed extraction leaves the shelf empty, not the app broken.
      _log.w('lut extraction failed', error: e);
    }
  }

  static String _displayName(String fileName) {
    final raw = p.basenameWithoutExtension(fileName).replaceAll('_', ' ');
    return raw.isEmpty ? fileName : raw[0].toUpperCase() + raw.substring(1);
  }
}
