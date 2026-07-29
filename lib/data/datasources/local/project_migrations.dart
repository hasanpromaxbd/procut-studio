/// Forward migrations for persisted project JSON.
///
/// Every stored project carries a `schema` number. On load, the raw map is run
/// through each migration above its version in order, so a project saved by
/// v1 of the app opens in v3 without the loader needing a single conditional.
///
/// Rules that keep this maintainable:
///   * migrations only ever move *forward*;
///   * each one is a pure `Map → Map` and is unit-tested against a real
///     fixture from that version;
///   * a project from a *newer* schema than we understand is refused rather
///     than silently mangled — better an honest error than a broken timeline.
library;

import '../../../core/constants/app_constants.dart';
import '../../../core/error/failure.dart';
import '../../../core/error/result.dart';
import '../../../core/logging/app_logger.dart';

typedef ProjectMigration = Map<String, dynamic> Function(Map<String, dynamic>);

abstract final class ProjectMigrations {
  static const _log = Log('ProjectMigrations');

  /// Keyed by the version being migrated *from*.
  static final Map<int, ProjectMigration> _migrations = {
    1: _v1ToV2,
    2: _v2ToV3,
  };

  static Result<Map<String, dynamic>> migrate(Map<String, dynamic> raw) {
    var version = (raw['schema'] as num?)?.toInt() ?? 1;

    if (version > AppConstants.projectSchemaVersion) {
      return Result.err(
        ProjectCorruptFailure(
          'This project was made with a newer version of ProCut Studio. '
          'Update the app to open it.',
          projectId: raw['id'] as String?,
        ),
      );
    }

    var current = raw;
    while (version < AppConstants.projectSchemaVersion) {
      final migration = _migrations[version];
      if (migration == null) {
        return Result.err(
          ProjectCorruptFailure(
            'This project uses an unsupported format (v$version).',
            projectId: raw['id'] as String?,
          ),
        );
      }
      try {
        current = migration(current);
      } catch (e, s) {
        _log.e('migration v$version failed', error: e, stackTrace: s);
        return Result.err(
          ProjectCorruptFailure(
            'This project could not be upgraded and may be damaged.',
            projectId: raw['id'] as String?,
            cause: e,
            stackTrace: s,
          ),
        );
      }
      version++;
      current['schema'] = version;
      _log.i('migrated to v$version', fields: {'id': current['id']});
    }
    return Result.ok(current);
  }

  /// v1 → v2: clip times moved from milliseconds to microseconds.
  ///
  /// Milliseconds could not represent a frame boundary at 29.97fps exactly,
  /// so long timelines accumulated visible drift between picture and sound.
  static Map<String, dynamic> _v1ToV2(Map<String, dynamic> raw) {
    final timeline = (raw['timeline'] as Map?)?.cast<String, dynamic>();
    if (timeline == null) return raw;

    for (final rawTrack in (timeline['tracks'] as List?) ?? const []) {
      final track = (rawTrack as Map).cast<String, dynamic>();
      for (final rawClip in (track['clips'] as List?) ?? const []) {
        final clip = (rawClip as Map).cast<String, dynamic>();
        _msToUs(clip, 'start', 'startUs');
        _msToUs(clip, 'duration', 'durUs');
        _msToUs(clip, 'sourceIn', 'inUs');
        _msToUs(clip, 'fadeIn', 'fadeInUs');
        _msToUs(clip, 'fadeOut', 'fadeOutUs');
      }
    }
    return raw;
  }

  /// v2 → v3: transitions moved from a track-level list onto the outgoing
  /// clip, so deleting a clip can no longer orphan a transition.
  static Map<String, dynamic> _v2ToV3(Map<String, dynamic> raw) {
    final timeline = (raw['timeline'] as Map?)?.cast<String, dynamic>();
    if (timeline == null) return raw;

    for (final rawTrack in (timeline['tracks'] as List?) ?? const []) {
      final track = (rawTrack as Map).cast<String, dynamic>();
      final legacy = (track.remove('transitions') as List?) ?? const [];
      if (legacy.isEmpty) continue;

      final clips = ((track['clips'] as List?) ?? const [])
          .map((c) => (c as Map).cast<String, dynamic>())
          .toList();

      for (final rawTransition in legacy) {
        final transition = (rawTransition as Map).cast<String, dynamic>();
        final fromId = transition.remove('fromClipId') as String?;
        if (fromId == null) continue;
        for (final clip in clips) {
          if (clip['id'] == fromId) {
            clip['outTransition'] = transition;
            break;
          }
        }
      }
    }
    return raw;
  }

  static void _msToUs(Map<String, dynamic> map, String oldKey, String newKey) {
    final value = map.remove(oldKey);
    if (value is num) map[newKey] = (value * 1000).round();
  }

  const ProjectMigrations._();
}
