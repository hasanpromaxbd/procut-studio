/// Template list and the save / apply flows.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../data/repositories/template_repository.dart';
import '../../domain/entities/project_template.dart';

final templateRepositoryProvider = Provider<TemplateRepository>(
  (ref) => TemplateRepository(store: ref.watch(hiveStoreProvider)),
);

final templateListProvider = FutureProvider<List<ProjectTemplate>>(
  (ref) async =>
      (await ref.watch(templateRepositoryProvider).list()).getOrElse(const []),
);

final templateControllerProvider = Provider<TemplateController>(
  TemplateController.new,
);

class TemplateController {
  TemplateController(this._ref);

  final Ref _ref;

  Future<Result<ProjectTemplate>> saveFromProject(
    String projectId, {
    required String name,
    String description = '',
  }) async {
    final loaded = await _ref.read(projectRepositoryProvider).load(projectId);
    if (loaded.isErr) return Result.err(loaded.failureOrNull!);

    final saved = await _ref
        .read(templateRepositoryProvider)
        .saveFromProject(
          loaded.valueOrNull!,
          name: name,
          description: description,
        );

    if (saved.isOk) _ref.invalidate(templateListProvider);
    return saved;
  }

  Future<Result<void>> delete(String templateId) async {
    final result = await _ref.read(templateRepositoryProvider).delete(templateId);
    if (result.isOk) _ref.invalidate(templateListProvider);
    return result;
  }

  /// Imports [paths], fills the template's slots, and saves the result as a
  /// new project.
  Future<Result<TemplateApplication>> applyTemplate(
    ProjectTemplate template,
    List<String> paths,
  ) async {
    final imported = await _ref
        .read(mediaRepositoryProvider)
        .importFiles(paths);
    if (imported.isErr) return Result.err(imported.failureOrNull!);

    final assets = imported.valueOrNull!;
    if (assets.isEmpty) {
      return const Result.err(
        UnsupportedMediaFailure('None of those files could be read as media.'),
      );
    }

    final applied = template.apply(
      projectName: template.name,
      assets: assets,
    );

    if (applied.filledSlots == 0) {
      return Result.err(
        InvalidEditFailure(
          'None of that media fits this template — it needs '
          '${template.slotCount} video or image clip(s).',
        ),
      );
    }

    final saved = await _ref
        .read(projectRepositoryProvider)
        .save(applied.project);
    if (saved.isErr) return Result.err(saved.failureOrNull!);

    return Result.ok(applied);
  }
}
