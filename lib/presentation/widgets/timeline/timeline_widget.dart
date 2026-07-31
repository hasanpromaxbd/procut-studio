/// The interactive timeline: gestures, thumbnail fetching, and two painters.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/utils/debouncer.dart';
import '../../../domain/entities/clip.dart';
import '../../../domain/entities/media_asset.dart';
import '../../../domain/entities/timeline.dart';
import '../../../engine/render/thumbnail_cache.dart';
import '../../../engine/timeline/timeline_view_state.dart';
import '../../viewmodels/editor_controller.dart';
import '../../viewmodels/playhead_controller.dart';
import '../../viewmodels/timeline_view_controller.dart';
import 'timeline_painter.dart';
import 'track_header_column.dart';

class TimelineWidget extends ConsumerStatefulWidget {
  const TimelineWidget({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<TimelineWidget> createState() => _TimelineWidgetState();
}

class _TimelineWidgetState extends ConsumerState<TimelineWidget> {
  /// Live drag state. Held as plain fields rather than provider state — a drag
  /// updates every frame and must not push through the whole app's rebuild
  /// machinery.
  String? _draggingClipId;
  ClipRegion? _dragRegion;
  Duration _dragGrabOffset = Duration.zero;
  Duration? _snapGuide;

  double _zoomStartPps = TimelineMetrics.basePixelsPerSecond;

  final Map<String, List<double>> _waveforms = {};
  final Set<String> _waveformRequests = {};
  final Throttler _thumbnailThrottle = Throttler(
    const Duration(milliseconds: 60),
  );

  @override
  void dispose() {
    _thumbnailThrottle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final view = ref.watch(timelineViewControllerProvider);
    final theme = Theme.of(context);

    if (editor == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final timeline = editor.timeline;
    final assetsById = <String, MediaAsset>{
      for (final entry in editor.project.assets.entries) entry.key: entry.value,
    };

    unawaited(_ensureWaveforms(timeline, assetsById));

    return LayoutBuilder(
      builder: (context, constraints) {
        // Reserve the header gutter; the painter's x axis starts after it.
        const headerWidth = 96.0;
        final trackWidth = constraints.maxWidth - headerWidth;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref
              .read(timelineViewControllerProvider.notifier)
              .setViewportWidth(trackWidth);
        });

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: headerWidth,
              child: TrackHeaderColumn(projectId: widget.projectId),
            ),
            Expanded(
              child: ClipRect(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _handleTap(details, view, timeline),
                  onDoubleTapDown: (details) =>
                      _handleDoubleTap(details, view, timeline),
                  // A double tap on a group opens it; the handler must exist
                  // for onDoubleTapDown to fire at all.
                  onDoubleTap: () {},
                  onScaleStart: (details) =>
                      _handleScaleStart(details, view, timeline),
                  onScaleUpdate: (details) =>
                      _handleScaleUpdate(details, view, timeline),
                  onScaleEnd: (_) => _handleScaleEnd(),
                  onLongPressStart: (details) =>
                      _handleLongPress(details, view, timeline),
                  child: CustomPaint(
                    size: Size(trackWidth, view.totalHeight(timeline)),
                    // The heavy layer: clips, thumbnails, waveforms.
                    painter: TimelinePainter(
                      timeline: timeline,
                      view: view,
                      selectedClipIds: editor.selectedClipIds,
                      colorScheme: theme.colorScheme,
                      thumbnails: ref.read(thumbnailCacheProvider),
                      assetsById: assetsById,
                      waveforms: _waveforms,
                      snapGuideTime: _snapGuide,
                      onThumbnailNeeded: (assetId, time) =>
                          _requestThumbnail(assetsById[assetId], time),
                    ),
                    // The cheap layer on top, repainted every playback frame.
                    foregroundPainter: _PlayheadRepaint(
                      ref: ref,
                      view: view,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Thumbnails & waveforms ───────────────────────────────────────────

  void _requestThumbnail(MediaAsset? asset, Duration time) {
    if (asset == null) return;
    // Throttled: the painter asks for every missing tile on every frame, and
    // without this a single scroll would queue hundreds of identical fetches.
    _thumbnailThrottle.run(() {
      final cache = ref.read(thumbnailCacheProvider);
      final key = ThumbnailCache.keyFor(asset, time);
      unawaited(
        cache.request(asset, key).then((image) {
          if (image != null && mounted) setState(() {});
        }),
      );
    });
  }

  Future<void> _ensureWaveforms(
    Timeline timeline,
    Map<String, MediaAsset> assets,
  ) async {
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        // Video clips carry audio too; their embedded track gets the same
        // waveform strip, which is how you cut dialogue without opening a
        // separate audio track.
        if (clip is! AudioClip && clip is! VideoClip) continue;
        final assetId = (clip as MediaClip).assetId;
        if (_waveforms.containsKey(assetId) ||
            _waveformRequests.contains(assetId)) {
          continue;
        }
        final asset = assets[assetId];
        if (asset == null || !asset.hasAudioStream) continue;

        _waveformRequests.add(assetId);
        final result = await ref.read(mediaRepositoryProvider).waveform(asset);
        final peaks = result.valueOrNull;
        if (peaks != null && mounted) {
          setState(() => _waveforms[assetId] = peaks.toList());
        }
      }
    }
  }

  // ── Gestures ─────────────────────────────────────────────────────────

  /// Double-tapping a group steps inside it.
  void _handleDoubleTap(
    TapDownDetails details,
    TimelineViewState view,
    Timeline timeline,
  ) {
    final hit = view.hitTest(
      timeline,
      details.localPosition.dx,
      details.localPosition.dy,
    );
    if (hit.clip is! CompoundClip) return;

    HapticFeedback.mediumImpact();
    ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .enterGroup(hit.clip!.id);
  }

  void _handleTap(
    TapDownDetails details,
    TimelineViewState view,
    Timeline timeline,
  ) {
    final hit = view.hitTest(
      timeline,
      details.localPosition.dx,
      details.localPosition.dy,
    );
    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );

    if (hit.region == ClipRegion.ruler || hit.region == ClipRegion.background) {
      ref.read(playheadControllerProvider.notifier).seek(hit.time);
      controller.select(null);
      return;
    }
    if (hit.isClip) {
      HapticFeedback.selectionClick();
      controller.select(hit.clip!.id, trackId: hit.track?.id);
    } else {
      controller.select(null);
      ref.read(playheadControllerProvider.notifier).seek(hit.time);
    }
  }

  void _handleLongPress(
    LongPressStartDetails details,
    TimelineViewState view,
    Timeline timeline,
  ) {
    final hit = view.hitTest(
      timeline,
      details.localPosition.dx,
      details.localPosition.dy,
    );
    if (!hit.isClip) return;
    HapticFeedback.mediumImpact();
    // Long-press extends the selection. A plain tap replaces it, so this is the
    // only way to build a multi-clip selection on a touch screen.
    ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .toggleSelection(hit.clip!.id, trackId: hit.track?.id);
  }

  void _handleScaleStart(
    ScaleStartDetails details,
    TimelineViewState view,
    Timeline timeline,
  ) {
    _zoomStartPps = view.pixelsPerSecond;

    // Two fingers is always a zoom, never a drag.
    if (details.pointerCount > 1) {
      _draggingClipId = null;
      return;
    }

    final hit = view.hitTest(
      timeline,
      details.localFocalPoint.dx,
      details.localFocalPoint.dy,
    );

    if (hit.isClip && !hit.clip!.locked && !(hit.track?.locked ?? false)) {
      _draggingClipId = hit.clip!.id;
      _dragRegion = hit.region;
      _dragGrabOffset = hit.time - hit.clip!.start;
      ref
          .read(editorControllerProvider(widget.projectId).notifier)
          ..select(hit.clip!.id, trackId: hit.track?.id)
          ..beginGesture(hit.isHandle ? 'trim' : 'move');
    } else if (hit.region == ClipRegion.ruler) {
      _draggingClipId = null;
      _dragRegion = ClipRegion.ruler;
      ref.read(playheadControllerProvider.notifier).beginScrub();
    } else {
      _draggingClipId = null;
      _dragRegion = null;
    }
  }

  void _handleScaleUpdate(
    ScaleUpdateDetails details,
    TimelineViewState view,
    Timeline timeline,
  ) {
    final viewController = ref.read(timelineViewControllerProvider.notifier);

    // Pinch zoom, anchored on the focal point.
    if (details.pointerCount > 1 && (details.scale - 1.0).abs() > 0.005) {
      final focusTime = view.viewportXToTime(details.localFocalPoint.dx);
      viewController.zoom(
        (_zoomStartPps * details.scale) / view.pixelsPerSecond,
        focusTime: focusTime,
        focusX: details.localFocalPoint.dx,
      );
      return;
    }

    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );

    // Scrubbing the ruler.
    if (_dragRegion == ClipRegion.ruler) {
      ref
          .read(playheadControllerProvider.notifier)
          .seek(view.viewportXToTime(details.localFocalPoint.dx));
      return;
    }

    final clipId = _draggingClipId;
    if (clipId == null) {
      // Nothing grabbed: pan.
      viewController.scrollBy(
        -details.focalPointDelta.dx,
        contentDuration: timeline.duration,
      );
      return;
    }

    final pointerTime = view.viewportXToTime(details.localFocalPoint.dx);
    final playhead = ref.read(playheadControllerProvider).position;

    switch (_dragRegion) {
      case ClipRegion.leftHandle:
        final snap = view.snap(
          pointerTime,
          timeline,
          playhead: playhead,
          excludeClipId: clipId,
        );
        setState(() => _snapGuide = snap.snapped ? snap.time : null);
        controller.trimStart(clipId, snap.time);

      case ClipRegion.rightHandle:
        final snap = view.snap(
          pointerTime,
          timeline,
          playhead: playhead,
          excludeClipId: clipId,
        );
        setState(() => _snapGuide = snap.snapped ? snap.time : null);
        controller.trimEnd(clipId, snap.time);

      default:
        // Preserve where inside the clip the finger grabbed it, so the clip
        // does not jump to centre under the pointer.
        final desired = pointerTime - _dragGrabOffset;
        final snap = view.snap(
          desired,
          timeline,
          playhead: playhead,
          excludeClipId: clipId,
        );
        setState(() => _snapGuide = snap.snapped ? snap.time : null);

        final targetTrack = view
            .hitTest(timeline, details.localFocalPoint.dx, details.localFocalPoint.dy)
            .track;
        controller.moveClipLive(
          clipId,
          snap.time,
          targetTrackId: targetTrack?.id,
        );
    }
  }

  void _handleScaleEnd() {
    if (_dragRegion == ClipRegion.ruler) {
      ref.read(playheadControllerProvider.notifier).endScrub();
    }
    if (_draggingClipId != null) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _draggingClipId = null;
      _dragRegion = null;
      _snapGuide = null;
    });
  }
}

/// Wraps [PlayheadPainter] so it can watch the playhead provider directly and
/// repaint without the parent widget rebuilding.
class _PlayheadRepaint extends CustomPainter {
  _PlayheadRepaint({required this.ref, required this.view})
    : _state = ref.watch(playheadControllerProvider),
      super(repaint: _PlayheadListenable(ref));

  final WidgetRef ref;
  final TimelineViewState view;
  final PlayheadState _state;

  @override
  void paint(Canvas canvas, Size size) {
    PlayheadPainter(
      position: _state.position,
      view: view,
      isPlaying: _state.isPlaying,
    ).paint(canvas, size);
  }

  @override
  bool shouldRepaint(_PlayheadRepaint old) =>
      old._state.position != _state.position || old.view != view;
}

/// Bridges a Riverpod provider to a [Listenable] so `CustomPainter.repaint`
/// can drive playhead redraws without a `setState` on the whole timeline.
class _PlayheadListenable extends ChangeNotifier {
  _PlayheadListenable(WidgetRef ref) {
    _subscription = ref.listenManual<PlayheadState>(
      playheadControllerProvider,
      (_, _) => notifyListeners(),
    );
  }

  late final ProviderSubscription<PlayheadState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}
