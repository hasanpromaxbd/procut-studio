/// Multicam: sync several angles, then switch between them while watching.
///
/// The angles live here rather than on the timeline because they are a *view*
/// of existing media, not an edit. Switching produces ordinary cuts on an
/// ordinary track — so there is no multicam mode to be trapped in, and every
/// other tool keeps working on the result.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/logging/app_logger.dart';
import '../../domain/entities/media_asset.dart';
import '../../engine/audio/audio_sync.dart';
import 'editor_controller.dart';
import 'playhead_controller.dart';

@immutable
class CameraAngle {
  const CameraAngle({
    required this.asset,
    required this.offset,
    this.confidence = 1,
    this.synced = false,
  });

  final MediaAsset asset;

  /// Where this angle's zero sits on the timeline. Derived from the audio
  /// sync, or zero when the user declined to sync.
  final Duration offset;

  final double confidence;
  final bool synced;

  String get label => asset.displayName.isEmpty
      ? asset.path.split('/').last
      : asset.displayName;

  /// The point in this angle's own footage that is on screen at [timelineAt].
  Duration sourceTimeAt(Duration timelineAt) {
    final at = timelineAt - offset;
    return at < Duration.zero ? Duration.zero : at;
  }

  CameraAngle copyWith({Duration? offset, double? confidence, bool? synced}) =>
      CameraAngle(
        asset: asset,
        offset: offset ?? this.offset,
        confidence: confidence ?? this.confidence,
        synced: synced ?? this.synced,
      );
}

@immutable
class MulticamState {
  const MulticamState({
    this.angles = const [],
    this.isSyncing = false,
    this.message,
  });

  final List<CameraAngle> angles;
  final bool isSyncing;
  final String? message;

  bool get isReady => angles.length >= 2;
}

final multicamProvider =
    NotifierProvider.family<MulticamController, MulticamState, String>(
      MulticamController.new,
    );

class MulticamController extends Notifier<MulticamState> {
  MulticamController(this.projectId);

  final String projectId;
  static const _log = Log('Multicam');

  @override
  MulticamState build() => const MulticamState();

  /// Adds an angle, unsynced. Sync is a separate, explicit step so the user
  /// sees what it decided before any of it reaches the timeline.
  void addAngle(MediaAsset asset) {
    if (state.angles.any((a) => a.asset.id == asset.id)) return;
    state = MulticamState(
      angles: [...state.angles, CameraAngle(asset: asset, offset: Duration.zero)],
      message: null,
    );
  }

  void removeAngle(String assetId) => state = MulticamState(
    angles: state.angles.where((a) => a.asset.id != assetId).toList(),
  );

  /// Lines every angle up against the first by their audio.
  ///
  /// The first angle is the reference and keeps offset zero — some angle has
  /// to be the clock, and "the one you added first" is the least surprising
  /// choice.
  Future<void> syncByAudio() async {
    if (state.angles.length < 2) return;
    state = MulticamState(angles: state.angles, isSyncing: true);

    final media = ref.read(mediaRepositoryProvider);
    final reference = await media.waveform(state.angles.first.asset);
    final referencePeaks = reference.valueOrNull;
    if (referencePeaks == null) {
      state = MulticamState(
        angles: state.angles,
        message: 'Could not read the first angle\u2019s audio.',
      );
      return;
    }

    final synced = <CameraAngle>[state.angles.first.copyWith(synced: true)];
    var weak = 0;

    for (final angle in state.angles.skip(1)) {
      final peaks = (await media.waveform(angle.asset)).valueOrNull;
      if (peaks == null) {
        synced.add(angle);
        weak++;
        continue;
      }

      final result = AudioSync.align(referencePeaks, peaks);
      if (!result.isTrustworthy) weak++;
      synced.add(
        angle.copyWith(
          // An untrustworthy match is left at zero rather than applied:
          // a confidently wrong offset is worse than an obvious one.
          offset: result.isTrustworthy ? result.offset : Duration.zero,
          confidence: result.confidence,
          synced: result.isTrustworthy,
        ),
      );
      _log.i('angle aligned', fields: {
        'asset': angle.asset.id,
        'offsetMs': result.offset.inMilliseconds,
        'confidence': result.confidence.toStringAsFixed(2),
      });
    }

    state = MulticamState(
      angles: synced,
      message: weak == 0
          ? 'All angles matched.'
          : '$weak angle(s) could not be matched by sound — set those by '
                'hand, or check they are the same take.',
    );
  }

  /// Nudges one angle's offset, for a take the audio could not match.
  void nudge(String assetId, Duration by) => state = MulticamState(
    angles: [
      for (final angle in state.angles)
        if (angle.asset.id == assetId)
          angle.copyWith(offset: angle.offset + by)
        else
          angle,
    ],
    message: state.message,
  );

  /// Switches the programme to [assetId] from the playhead onward.
  void switchTo(String assetId) {
    final angle = state.angles.where((a) => a.asset.id == assetId).firstOrNull;
    final editor = ref.read(editorControllerProvider(projectId));
    final clipId = editor?.selectedClipId;
    if (angle == null || editor == null || clipId == null) return;

    final at = ref.read(playheadControllerProvider).position;
    ref
        .read(editorControllerProvider(projectId).notifier)
        .switchAngle(
          clipId,
          at,
          asset: angle.asset,
          sourceIn: angle.sourceTimeAt(at),
          label: angle.label,
        );
  }
}
