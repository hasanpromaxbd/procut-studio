/// Bdrive backup settings and the backup action.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../data/datasources/remote/bdrive_client.dart';

final bdriveSettingsProvider =
    NotifierProvider<BdriveSettingsController, BdriveSettings>(
      BdriveSettingsController.new,
    );

class BdriveSettingsController extends Notifier<BdriveSettings> {
  static const _key = 'bdrive';

  @override
  BdriveSettings build() {
    final raw = ref.read(hiveStoreProvider).settings.get(_key);
    if (raw == null || raw.isEmpty) return const BdriveSettings();
    try {
      return BdriveSettings.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return const BdriveSettings();
    }
  }

  void save(BdriveSettings settings) {
    state = settings.normalised();
    unawaited(
      ref
          .read(hiveStoreProvider)
          .settings
          .put(_key, jsonEncode(state.toJson())),
    );
  }
}

/// One backup run: bundle the project, upload it, report back.
///
/// Returns null on success, otherwise the error message. Progress covers the
/// upload only — bundling is fast and local.
final bdriveBackupProvider = Provider<
    Future<String?> Function(
      String projectId, {
      void Function(double progress)? onProgress,
    })>((ref) {
  return (projectId, {onProgress}) async {
    final settings = ref.read(bdriveSettingsProvider);
    if (!settings.isConfigured) {
      return 'Set up Bdrive in Settings first.';
    }

    final bundled =
        await ref.read(projectRepositoryProvider).exportBundle(projectId);
    final path = bundled.valueOrNull;
    if (path == null) {
      return bundled.failureOrNull?.message ?? 'Could not bundle the project.';
    }

    final client = BdriveClient(
      dio: ref.read(dioProvider),
      settings: settings,
    );
    final uploaded = await client.uploadFile(
      File(path),
      onProgress: onProgress,
    );
    return uploaded.fold(
      (_) => null,
      (failure) => failure.message,
    );
  };
});
