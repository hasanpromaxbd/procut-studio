/// Project library state for the home screen.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/error/result.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/timeline.dart';

enum ProjectSort {
  recent('Recently edited'),
  name('Name'),
  duration('Duration');

  const ProjectSort(this.label);
  final String label;
}

final projectSortProvider = NotifierProvider<ProjectSortController, ProjectSort>(
  ProjectSortController.new,
);

class ProjectSortController extends Notifier<ProjectSort> {
  @override
  ProjectSort build() => ProjectSort.recent;
  void set(ProjectSort sort) => state = sort;
}

/// Live project list, re-emitted whenever anything is saved or deleted.
/// What the user has typed into the home screen's search box.
///
/// Deliberately not persisted: a filter still applied next time you open the
/// app looks exactly like half your projects having vanished.
final projectQueryProvider = NotifierProvider<ProjectQueryController, String>(
  ProjectQueryController.new,
);

class ProjectQueryController extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void clear() => state = '';
}

final projectListProvider = StreamProvider<List<ProjectSummary>>((ref) {
  final sort = ref.watch(projectSortProvider);
  final query = ref.watch(projectQueryProvider).trim().toLowerCase();
  return ref.watch(projectRepositoryProvider).watchSummaries().map((projects) {
    final sorted = List<ProjectSummary>.of(projects);
    switch (sort) {
      case ProjectSort.recent:
        sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case ProjectSort.name:
        sorted.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case ProjectSort.duration:
        sorted.sort((a, b) => b.duration.compareTo(a.duration));
    }
    if (query.isEmpty) return sorted;
    // Matching on every word separately means "beach 4k" finds "4K beach
    // edit" — people rarely remember the exact order of their own titles.
    final terms = query.split(RegExp(r'\s+'));
    return sorted.where((project) {
      final haystack = project.name.toLowerCase();
      return terms.every(haystack.contains);
    }).toList();
  });
});

final homeControllerProvider =
    AsyncNotifierProvider<HomeController, void>(HomeController.new);

class HomeController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// Creates a project and returns its id, or null on failure.
  Future<String?> createProject({
    required String name,
    AspectPreset aspect = AspectPreset.vertical9x16,
    int fps = 30,
  }) async {
    final project = Project.empty(
      id: IdGenerator.project(),
      name: name.trim().isEmpty ? 'Untitled project' : name.trim(),
      videoTrackId: IdGenerator.track(),
      audioTrackId: IdGenerator.track(),
      aspect: aspect,
      fps: fps,
    );

    state = const AsyncValue.loading();
    final result = await ref.read(projectRepositoryProvider).save(project);
    return result.fold(
      (_) {
        state = const AsyncValue.data(null);
        return project.id;
      },
      (failure) {
        state = AsyncValue.error(failure, StackTrace.current);
        return null;
      },
    );
  }

  Future<Result<void>> deleteProject(String projectId) =>
      ref.read(projectRepositoryProvider).delete(projectId);

  Future<String?> duplicateProject(String projectId) async {
    final result = await ref
        .read(projectRepositoryProvider)
        .duplicate(projectId);
    return result.valueOrNull?.id;
  }

  Future<Result<void>> renameProject(String projectId, String name) =>
      ref.read(projectRepositoryProvider).rename(projectId, name);

  Future<Result<String>> exportBundle(String projectId) =>
      ref.read(projectRepositoryProvider).exportBundle(projectId);

  Future<Result<Project>> importBundle(String path) async {
    state = const AsyncValue.loading();
    final result = await ref
        .read(projectRepositoryProvider)
        .importBundle(path);
    state = result.fold(
      (_) => const AsyncValue.data(null),
      (failure) => AsyncValue.error(failure, StackTrace.current),
    );
    return result;
  }

  /// Projects whose media has gone missing — surfaced as a relink prompt
  /// rather than discovered at export time.
  Future<Result<int>> countMissingMedia(String projectId) async {
    final loaded = await ref.read(projectRepositoryProvider).load(projectId);
    return loaded.fold(
      (project) => Result.ok(
        project.missingAssets((path) => File(path).existsSync()).length,
      ),
      Result<int>.err,
    );
  }
}
