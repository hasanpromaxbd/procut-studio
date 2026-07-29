/// AI tools.
///
/// The sheet deliberately separates the two kinds. The local tools run on the
/// device with no model and no network; the model-backed ones need a
/// configured backend and are shown greyed with a route to Settings rather than
/// hidden — a hidden feature reads as missing, a disabled one with a reason
/// reads as configurable.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/entities/media_asset.dart';
import '../../../../domain/repositories/ai_repository.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';
import '../../settings/settings_screen.dart';
import 'tracking_sheet.dart';

class AiToolsSheet extends ConsumerStatefulWidget {
  const AiToolsSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<AiToolsSheet> createState() => _AiToolsSheetState();
}

class _AiToolsSheetState extends ConsumerState<AiToolsSheet> {
  AiCapability? _running;
  double _progress = 0;
  String? _status;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final capabilities = ref.watch(aiCapabilitiesProvider);
    final theme = Theme.of(context);

    final clipId = editor?.selectedClipId;
    final found = clipId == null ? null : editor!.timeline.findClip(clipId);
    final clip = found?.$2;
    final asset = clip is MediaClip ? editor!.project.asset(clip.assetId) : null;

    return ToolSheet(
      title: 'AI tools',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (clip == null)
            Text(
              'Select a clip to run a tool on it.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

          if (_running != null) ...[
            const SizedBox(height: Spacing.md),
            LinearProgressIndicator(
              value: _progress <= 0 ? null : _progress.clamp(0.0, 1.0),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              _status ?? _running!.label,
              style: theme.textTheme.bodySmall,
            ),
          ],

          if (_error != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],

          const SectionHeader(title: 'Runs on this device'),
          Text(
            'Signal processing, not a neural model. Works offline.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.sm),

          _ToolTile(
            icon: Icons.auto_fix_high_rounded,
            title: 'Enhance colour',
            subtitle: 'Measures the frame and adds a correction you can tune',
            enabled: asset != null && _running == null,
            onTap: () => _run(
              AiCapability.colorEnhancement,
              () => _enhanceColour(asset!),
            ),
          ),
          _ToolTile(
            icon: Icons.movie_filter_rounded,
            title: 'Detect scenes',
            subtitle: 'Finds hard cuts and splits the clip at each one',
            enabled: asset != null &&
                asset.kind == AssetKind.video &&
                _running == null,
            onTap: () => _run(
              AiCapability.sceneDetection,
              () => _detectScenes(asset!),
            ),
          ),
          _ToolTile(
            icon: Icons.hd_rounded,
            title: 'Upscale',
            subtitle: 'Lanczos resampling — sharper, but invents no detail',
            enabled: asset != null &&
                asset.kind == AssetKind.video &&
                _running == null,
            onTap: () => _run(
              AiCapability.upscaling,
              () => _upscale(asset!),
            ),
          ),
          _ToolTile(
            icon: Icons.record_voice_over_rounded,
            title: 'Isolate voice',
            subtitle: 'Cleans a voice recording; will not unmix a song',
            enabled: asset != null && _running == null,
            onTap: () => _run(
              AiCapability.voiceIsolation,
              () => _isolateVoice(asset!),
            ),
          ),

          const SectionHeader(title: 'Needs an AI server'),
          capabilities.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Text('$error'),
            data: (available) {
              final hasBackend = available.contains(AiCapability.autoCaption);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!hasBackend)
                    Card(
                      color: theme.colorScheme.surfaceContainerHigh,
                      child: Padding(
                        padding: const EdgeInsets.all(Spacing.md),
                        child: Row(
                          children: [
                            Icon(
                              Icons.cloud_off_rounded,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: Spacing.sm),
                            Expanded(
                              child: Text(
                                'No AI server configured. These need one — '
                                'ProCut ships no models.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const SettingsScreen(),
                                ),
                              ),
                              child: const Text('Set up'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: Spacing.sm),
                  _ToolTile(
                    icon: Icons.closed_caption_rounded,
                    title: 'Auto captions',
                    subtitle: 'Transcribes speech onto its own caption track',
                    enabled: hasBackend &&
                        asset != null &&
                        _running == null,
                    onTap: () => _run(
                      AiCapability.autoCaption,
                      () => _autoCaption(asset!, clip!),
                    ),
                  ),
                  _ToolTile(
                    icon: Icons.my_location_rounded,
                    title: 'Motion tracking',
                    subtitle: 'Follow a subject and drive a sticker or title',
                    enabled: (available.contains(AiCapability.objectTracking) ||
                            available.contains(AiCapability.faceTracking)) &&
                        clip is MediaClip &&
                        _running == null,
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(
                        ToolSheet.show<void>(
                          context,
                          sheet: TrackingSheet(projectId: widget.projectId),
                        ),
                      );
                    },
                  ),
                  _ToolTile(
                    icon: Icons.person_remove_rounded,
                    title: 'Remove background',
                    subtitle: 'Generates an alpha matte for the subject',
                    enabled: available.contains(
                          AiCapability.backgroundRemoval,
                        ) &&
                        asset != null &&
                        _running == null,
                    onTap: () => _run(
                      AiCapability.backgroundRemoval,
                      () => _removeBackground(asset!),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Runner ───────────────────────────────────────────────────────────

  Future<void> _run(
    AiCapability capability,
    Future<String?> Function() action,
  ) async {
    setState(() {
      _running = capability;
      _progress = 0;
      _status = null;
      _error = null;
    });

    try {
      final message = await action();
      if (!mounted) return;
      setState(() {
        _running = null;
        _status = message;
      });
      if (message != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _running = null;
          _error = '$e';
        });
      }
    }
  }

  void _onProgress(double value) {
    if (mounted) setState(() => _progress = value);
  }

  EditorController get _editor =>
      ref.read(editorControllerProvider(widget.projectId).notifier);

  AiRepository get _ai => ref.read(aiRepositoryProvider);

  // ── Individual tools ─────────────────────────────────────────────────

  Future<String?> _enhanceColour(MediaAsset asset) async {
    final result = await _ai.suggestColorEnhancement(asset);
    return result.fold(
      (values) {
        _editor.applyColorSuggestion(values);
        return 'Colour correction added — tune it in Effects';
      },
      (failure) {
        setState(() => _error = failure.message);
        return null;
      },
    );
  }

  Future<String?> _detectScenes(MediaAsset asset) async {
    setState(() => _status = 'Analysing scenes');
    final result = await _ai.detectScenes(asset, onProgress: _onProgress);
    return result.fold(
      (cuts) {
        if (cuts.isEmpty) return 'No scene changes found';
        final applied = _editor.applySceneCuts(
          cuts.map((c) => c.time).toList(),
        );
        return applied == 0
            ? 'No cuts fell inside this clip'
            : '$applied scene cut(s) applied';
      },
      (failure) {
        setState(() => _error = failure.message);
        return null;
      },
    );
  }

  Future<String?> _upscale(MediaAsset asset) async {
    // Doubling the short edge is the useful default; going further is slower
    // than the encode itself for no visible gain on a phone screen.
    final target = (asset.displayHeight * 2).clamp(720, 2160);
    setState(() => _status = 'Upscaling to ${target}p — this re-encodes');

    final result = await _ai.upscale(
      asset,
      targetHeight: target,
      onProgress: _onProgress,
    );
    return await result.fold(
      (path) async {
        await _editor.replaceSelectedMedia(path);
        return 'Upscaled to ${target}p';
      },
      (failure) {
        setState(() => _error = failure.message);
        return null;
      },
    );
  }

  Future<String?> _isolateVoice(MediaAsset asset) async {
    setState(() => _status = 'Cleaning audio');
    final result = await _ai.isolateVoice(asset, onProgress: _onProgress);
    return await result.fold(
      (path) async {
        await _editor.replaceSelectedMedia(path);
        return 'Voice isolated';
      },
      (failure) {
        setState(() => _error = failure.message);
        return null;
      },
    );
  }

  Future<String?> _autoCaption(MediaAsset asset, Clip clip) async {
    setState(() => _status = 'Transcribing — this runs on your AI server');

    final result = await _ai.autoCaption(asset, onProgress: _onProgress);
    return result.fold(
      (track) {
        // Offset by the clip's timeline position: the recogniser works in
        // source time and knows nothing about where the clip sits.
        _editor.addSubtitles(track, offset: clip.start);
        return '${track.cues.length} captions added over '
            '${TimeUtils.formatShort(track.duration)}';
      },
      (failure) {
        setState(() => _error = failure.message);
        return null;
      },
    );
  }

  Future<String?> _removeBackground(MediaAsset asset) async {
    setState(() => _status = 'Generating matte');
    final result = await _ai.removeBackground(asset, onProgress: _onProgress);
    return result.fold(
      (path) => 'Matte ready at $path',
      (failure) {
        setState(() => _error = failure.message);
        return null;
      },
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title, style: theme.textTheme.bodyLarge),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
