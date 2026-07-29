/// Template persistence.
///
/// Templates live in their own Hive box rather than alongside projects: they
/// are a different lifecycle (kept indefinitely, applied many times) and mixing
/// them would make the home grid's project scan read rows it must then filter
/// out.
library;

import 'dart:convert';

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_template.dart';
import '../datasources/local/hive_store.dart';

class TemplateRepository {
  TemplateRepository({required HiveStore store}) : _store = store;

  static const _log = Log('TemplateRepository');
  static const String _prefix = 'template.';

  final HiveStore _store;

  Future<Result<List<ProjectTemplate>>> list() async => guard(() async {
    final templates = <ProjectTemplate>[];
    for (final key in _store.settings.keys) {
      if (key is! String || !key.startsWith(_prefix)) continue;
      final raw = _store.settings.get(key);
      if (raw == null) continue;
      try {
        templates.add(
          ProjectTemplate.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      } catch (e) {
        // One unreadable template must not hide the rest.
        _log.w('skipping unreadable template $key', error: e);
      }
    }
    templates.sort(
      (a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
    );
    return templates;
  }, onError: (e, s) => StorageFailure(
        'Could not read your templates.',
        cause: e,
        stackTrace: s,
      ));

  Future<Result<ProjectTemplate>> saveFromProject(
    Project project, {
    required String name,
    String description = '',
  }) async {
    if (project.timeline.clipCount == 0) {
      return const Result.err(
        InvalidEditFailure('There is nothing on the timeline to save.'),
      );
    }

    final template = ProjectTemplate.fromProject(
      project,
      name: name,
      description: description,
    );

    if (template.slotCount == 0) {
      return const Result.err(
        InvalidEditFailure(
          'A template needs at least one video, image or audio clip — a '
          'text-only edit has nothing to swap.',
        ),
      );
    }

    final saved = await guard(() async {
      await _store.settings.put(
        '$_prefix${template.id}',
        jsonEncode(template.toJson()),
      );
    }, onError: (e, s) => StorageFailure(
          'Could not save the template.',
          cause: e,
          stackTrace: s,
        ));

    if (saved.isErr) return Result.err(saved.failureOrNull!);
    _log.i('template saved', fields: {'id': template.id, 'slots': template.slotCount});
    return Result.ok(template);
  }

  Future<Result<void>> delete(String templateId) async => guard(() async {
    await _store.settings.delete('$_prefix$templateId');
  }, onError: (e, s) => StorageFailure(
        'Could not delete the template.',
        cause: e,
        stackTrace: s,
      ));
}
