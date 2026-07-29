/// Writes the AI backend configuration.
///
/// Reading lives in `core/di/providers.dart` so the DI graph never depends
/// upward on presentation. This class only persists and invalidates.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../data/datasources/remote/http_ai_backend.dart';

final aiSettingsControllerProvider =
    Provider<AiSettingsController>(AiSettingsController.new);

class AiSettingsController {
  AiSettingsController(this._ref);

  final Ref _ref;

  AiSettings get current => _ref.read(aiSettingsProvider);

  Future<void> save(AiSettings settings) async {
    final normalised = settings.normalised();
    await _ref
        .read(hiveStoreProvider)
        .settings
        .put(aiSettingsKey, jsonEncode(normalised.toJson()));
    _invalidate();
  }

  Future<void> clear() async {
    await _ref.read(hiveStoreProvider).settings.delete(aiSettingsKey);
    _invalidate();
  }

  /// Rebuilds the backend and everything derived from it, so the UI reflects a
  /// new address without an app restart.
  void _invalidate() {
    _ref
      ..invalidate(aiSettingsProvider)
      ..invalidate(aiBackendProvider)
      ..invalidate(aiBackendReachableProvider)
      ..invalidate(aiCapabilitiesProvider);
  }
}
