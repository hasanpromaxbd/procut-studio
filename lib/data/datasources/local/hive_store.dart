/// Hive setup and typed box access.
///
/// **Why projects are stored as JSON strings rather than Hive TypeAdapters.**
/// A project is a deep, evolving graph — five clip kinds, animatable
/// properties, effects with open-ended parameter maps. Binary TypeAdapters bind
/// that shape into generated code and require a hand-written migration for
/// every field added, with a corrupted box as the failure mode when one is
/// missed. Storing canonical JSON keeps Hive doing the one thing it is
/// excellent at — a fast, crash-safe key/value log — while schema evolution
/// stays explicit and testable in [ProjectMigrations]. The cost is a parse on
/// load, which for a 200 kB project is under a millisecond.
///
/// Note this uses `hive_ce`, the maintained community fork. The original
/// `hive` package has been unmaintained since 2023.
library;

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/error/failure.dart';
import '../../../core/error/result.dart';
import '../../../core/logging/app_logger.dart';

class HiveStore {
  HiveStore();

  static const _log = Log('HiveStore');

  Box<String>? _projects;
  Box<String>? _settings;
  Box<String>? _mediaMeta;
  Box<String>? _recents;

  bool get isOpen => _projects != null;

  Future<Result<void>> init({String subDirectory = 'procut'}) async {
    try {
      await Hive.initFlutter(subDirectory);
      _projects = await Hive.openBox<String>(AppConstants.boxProjects);
      _settings = await Hive.openBox<String>(AppConstants.boxSettings);
      _mediaMeta = await Hive.openBox<String>(AppConstants.boxMediaMeta);
      _recents = await Hive.openBox<String>(AppConstants.boxRecents);
      _log.i(
        'opened',
        fields: {'projects': _projects?.length ?? 0},
      );
      return const Result.ok(null);
    } catch (e, s) {
      _log.e('init failed', error: e, stackTrace: s);
      return Result.err(
        StorageFailure(
          'ProCut could not open its local database.',
          cause: e,
          stackTrace: s,
        ),
      );
    }
  }

  Box<String> get projects => _require(_projects, AppConstants.boxProjects);
  Box<String> get settings => _require(_settings, AppConstants.boxSettings);
  Box<String> get mediaMeta => _require(_mediaMeta, AppConstants.boxMediaMeta);
  Box<String> get recents => _require(_recents, AppConstants.boxRecents);

  Box<String> _require(Box<String>? box, String name) {
    if (box == null || !box.isOpen) {
      throw StateError('Hive box "$name" is not open — call HiveStore.init()');
    }
    return box;
  }

  /// Reclaims space from deleted entries. Hive appends to a log, so a box that
  /// has seen many saves keeps growing until it is compacted.
  Future<void> compact() async {
    for (final box in [_projects, _settings, _mediaMeta, _recents]) {
      if (box != null && box.isOpen) await box.compact();
    }
    _log.d('compacted');
  }

  Future<void> close() async {
    await Hive.close();
    _projects = null;
    _settings = null;
    _mediaMeta = null;
    _recents = null;
  }

  /// Test hook — wipes everything.
  Future<void> clear() async {
    for (final box in [_projects, _settings, _mediaMeta, _recents]) {
      if (box != null && box.isOpen) await box.clear();
    }
  }
}
