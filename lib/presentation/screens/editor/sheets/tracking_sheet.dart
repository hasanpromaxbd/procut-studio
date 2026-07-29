/// Motion tracking: pick a region, track it, attach a layer to the result.
///
/// The output is nothing exotic — a list of positions over time, which is
/// exactly an animation curve. `EditorController.applyTracking` turns it into
/// transform keyframes, so a tracked sticker is indistinguishable from one
/// keyframed by hand and can be edited afterwards the same way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/repositories/ai_repository.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class TrackingSheet extends ConsumerStatefulWidget {
  const TrackingSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<TrackingSheet> createState() => _TrackingSheetState();
}

class _TrackingSheetState extends ConsumerState<TrackingSheet> {
  // Normalised region to track, as fractions of the frame.
  double _x = 0.35;
  double _y = 0.35;
  double _size = 0.3;

  bool _running = false;
  double _progress = 0;
  String? _status;
  String? _error;
  TrackingResult? _result;

  /// The layer the tracked path will drive. Defaults to the selected clip,
  /// which is usually the sticker or title the user just added.
  String? _targetClipId;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final capabilities = ref.watch(aiCapabilitiesProvider);
    final theme = Theme.of(context);

    final clipId = editor?.selectedClipId;
    final found = clipId == null ? null : editor!.timeline.findClip(clipId);
    final clip = found?.$2;
    _targetClipId ??= clipId;

    final trackable = clip is MediaClip
        ? editor!.project.asset(clip.assetId)
        : null;

    return ToolSheet(
      title: 'Motion tracking',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tracks a region across the clip and turns the path into position '
            'keyframes on a layer. Needs an AI server with a tracking endpoint.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          capabilities.when(
            loading: () => const Padding(
              padding: EdgeInsets.only(top: Spacing.md),
              child: LinearProgressIndicator(),
            ),
            error: (error, _) => Text('$error'),
            data: (available) {
              final hasObject = available.contains(AiCapability.objectTracking);
              final hasFaces = available.contains(AiCapability.faceTracking);

              if (!hasObject && !hasFaces) {
                return Padding(
                  padding: const EdgeInsets.only(top: Spacing.md),
                  child: Card(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.all(Spacing.md),
                      child: Text(
                        'No tracking endpoint is configured. Set an AI server '
                        'up in Settings, then come back.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(title: 'Region to track'),
                  _RegionPreview(x: _x, y: _y, size: _size),
                  const SizedBox(height: Spacing.sm),
                  LabeledSlider(
                    label: 'Horizontal',
                    value: _x,
                    min: 0,
                    max: 1 - _size,
                    formatter: (v) => '${(v * 100).round()}%',
                    onChanged: (v) => setState(() => _x = v),
                  ),
                  LabeledSlider(
                    label: 'Vertical',
                    value: _y,
                    min: 0,
                    max: 1 - _size,
                    formatter: (v) => '${(v * 100).round()}%',
                    onChanged: (v) => setState(() => _y = v),
                  ),
                  LabeledSlider(
                    label: 'Size',
                    value: _size,
                    min: 0.05,
                    max: 0.8,
                    formatter: (v) => '${(v * 100).round()}%',
                    onChanged: (v) => setState(() {
                      _size = v;
                      // Keep the box inside the frame as it grows.
                      _x = _x.clamp(0.0, 1 - v);
                      _y = _y.clamp(0.0, 1 - v);
                    }),
                  ),

                  if (_running) ...[
                    const SizedBox(height: Spacing.md),
                    LinearProgressIndicator(
                      value: _progress <= 0 ? null : _progress,
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(_status ?? 'Tracking', style: theme.textTheme.bodySmall),
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

                  if (_result != null && !_running) ...[
                    const SizedBox(height: Spacing.md),
                    Card(
                      color: theme.colorScheme.surfaceContainerHigh,
                      child: Padding(
                        padding: const EdgeInsets.all(Spacing.md),
                        child: Text(
                          '${_result!.points.length} points tracked. Select the '
                          'layer to attach, then apply.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                    const SectionHeader(title: 'Attach to'),
                    RadioGroup<String>(
                      groupValue: _targetClipId,
                      onChanged: (v) => setState(() => _targetClipId = v),
                      child: Column(
                        children: [
                          for (final track in editor!.timeline.tracks)
                            for (final candidate in track.clips)
                              if (candidate.kind == ClipKind.sticker ||
                                  candidate.kind == ClipKind.text)
                                RadioListTile<String>(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  value: candidate.id,
                                  title: Text(
                                    candidate is TextClip
                                        ? candidate.text
                                        : (candidate.label ?? 'Sticker'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: Spacing.xl),
                  if (_result == null)
                    GradientButton(
                      label: 'Track region',
                      icon: Icons.my_location_rounded,
                      expand: true,
                      busy: _running,
                      onPressed: trackable == null || _running
                          ? null
                          : () => _track(clip! as MediaClip),
                    )
                  else
                    GradientButton(
                      label: 'Apply to layer',
                      icon: Icons.check_rounded,
                      expand: true,
                      onPressed: _targetClipId == null ? null : _apply,
                    ),

                  if (hasFaces && _result == null) ...[
                    const SizedBox(height: Spacing.sm),
                    OutlinedButton.icon(
                      onPressed: trackable == null || _running
                          ? null
                          : () => _trackFaces(clip! as MediaClip),
                      icon: const Icon(Icons.face_rounded),
                      label: const Text('Track the largest face instead'),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _track(MediaClip clip) async {
    final asset = ref
        .read(editorControllerProvider(widget.projectId))
        ?.project
        .asset(clip.assetId);
    if (asset == null) return;

    setState(() {
      _running = true;
      _progress = 0;
      _error = null;
      _status = 'Uploading and tracking';
    });

    final result = await ref.read(aiRepositoryProvider).trackObject(
          asset,
          x: _x,
          y: _y,
          width: _size,
          height: _size,
          from: clip.sourceIn,
          to: clip.sourceIn + clip.sourceDuration,
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        );

    if (!mounted) return;
    result.fold(
      (tracking) => setState(() {
        _running = false;
        _result = tracking;
      }),
      (failure) => setState(() {
        _running = false;
        _error = failure.message;
      }),
    );
  }

  Future<void> _trackFaces(MediaClip clip) async {
    final asset = ref
        .read(editorControllerProvider(widget.projectId))
        ?.project
        .asset(clip.assetId);
    if (asset == null) return;

    setState(() {
      _running = true;
      _progress = 0;
      _error = null;
      _status = 'Finding faces';
    });

    final result = await ref.read(aiRepositoryProvider).trackFaces(
          asset,
          from: clip.sourceIn,
          to: clip.sourceIn + clip.sourceDuration,
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        );

    if (!mounted) return;
    result.fold(
      (tracks) {
        if (tracks.isEmpty) {
          setState(() {
            _running = false;
            _error = 'No faces were found in this clip.';
          });
          return;
        }
        // The longest track is almost always the subject; a two-frame
        // detection in the background is noise.
        tracks.sort((a, b) => b.points.length.compareTo(a.points.length));
        setState(() {
          _running = false;
          _result = tracks.first;
        });
      },
      (failure) => setState(() {
        _running = false;
        _error = failure.message;
      }),
    );
  }

  void _apply() {
    final tracking = _result;
    final target = _targetClipId;
    if (tracking == null || target == null) return;

    ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .applyTracking(tracking, clipId: target);

    // Park the playhead at the start of the tracked range so the result is
    // visible immediately rather than wherever the user happened to be.
    if (tracking.points.isNotEmpty) {
      ref
          .read(playheadControllerProvider.notifier)
          .seek(tracking.points.first.time);
    }
    Navigator.of(context).pop();
  }
}

/// Shows where the tracking box sits, as a proportion of the frame.
class _RegionPreview extends StatelessWidget {
  const _RegionPreview({
    required this.x,
    required this.y,
    required this.size,
  });

  final double x;
  final double y;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned(
                left: x * constraints.maxWidth,
                top: y * constraints.maxHeight,
                width: size * constraints.maxWidth,
                height: size * constraints.maxHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: theme.colorScheme.secondary,
                      width: 2,
                    ),
                    color: theme.colorScheme.secondary.withValues(alpha: 0.14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
