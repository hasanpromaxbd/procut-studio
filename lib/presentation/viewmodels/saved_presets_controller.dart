/// The user's own named export settings.
///
/// The platform presets say what YouTube or TikTok want; these say what *you*
/// want, which is usually a platform preset plus two changes you make every
/// single time. Stored as whole settings rather than as a diff so applying
/// one is predictable regardless of what the form currently holds.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../domain/entities/export_settings.dart';

@immutable
class SavedPreset {
  const SavedPreset({required this.name, required this.settings});

  final String name;
  final ExportSettings settings;

  Map<String, dynamic> toJson() => {
    'name': name,
    'settings': settings.toJson(),
  };

  static SavedPreset? fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String?;
    if (name == null || name.isEmpty) return null;
    return SavedPreset(
      name: name,
      settings: ExportSettings.fromJson(
        (json['settings'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}

final savedPresetsProvider =
    NotifierProvider<SavedPresetsController, List<SavedPreset>>(
      SavedPresetsController.new,
    );

class SavedPresetsController extends Notifier<List<SavedPreset>> {
  static const _key = 'exportPresets';

  @override
  List<SavedPreset> build() {
    final raw = ref.read(hiveStoreProvider).settings.get(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final entry in jsonDecode(raw) as List)
          ?SavedPreset.fromJson((entry as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      // A preset list that will not parse is not worth crashing the export
      // screen over; the user loses their presets, not their projects.
      return const [];
    }
  }

  /// Saves under [name], replacing any preset already using it.
  ///
  /// Replacing rather than appending: two presets with one name is a menu the
  /// user cannot navigate, and "save over it" is what they meant.
  void save(String name, ExportSettings settings) {
    final clean = name.trim();
    if (clean.isEmpty) return;
    state = [
      for (final preset in state)
        if (preset.name != clean) preset,
      SavedPreset(name: clean, settings: settings),
    ];
    _persist();
  }

  void remove(String name) {
    state = state.where((p) => p.name != name).toList();
    _persist();
  }

  void _persist() {
    unawaited(
      ref
          .read(hiveStoreProvider)
          .settings
          .put(_key, jsonEncode([for (final p in state) p.toJson()])),
    );
  }
}
