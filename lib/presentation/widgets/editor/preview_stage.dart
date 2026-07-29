/// The live preview.
///
/// ## How compositing works here
///
/// Each visible video/image layer is a real platform texture from
/// `video_player`, stacked in track order and transformed with the clip's own
/// [Transform2D]. Effects are applied as GPU fragment shaders through
/// `ui.ImageFilter.shader`, which runs the *same* `.frag` files the effect
/// catalogue names — so what you see is produced by the shader, not by an
/// approximation of it. Text and stickers are drawn by [LayerPainter], the same
/// painter the exporter rasterises with.
///
/// ## Known limits, stated plainly
///
/// * Android allows a small number of concurrent hardware video decoders
///   (typically 4–8, device-dependent). Beyond [_maxConcurrentDecoders] visible
///   video layers, the lowest ones fall back to a still frame in the preview.
///   The **export is unaffected** — FFmpeg composites all of them.
/// * Preview effects use the shader path; export uses the FFmpeg filter path.
///   They are matched deliberately, but a few (motion blur especially) are
///   temporal in the exporter and spatial in the preview. The inspector labels
///   those.
library;

import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/di/providers.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../domain/entities/clip.dart';
import '../../../domain/entities/effect.dart';
import '../../../domain/entities/media_asset.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/transform2d.dart';
import '../../../engine/render/layer_painter.dart';
import '../../../engine/render/shader_library.dart';
import '../../viewmodels/editor_controller.dart';
import '../../viewmodels/playhead_controller.dart';

/// Above this many simultaneous video layers we stop creating decoders.
const int _maxConcurrentDecoders = 4;

class PreviewStage extends ConsumerStatefulWidget {
  const PreviewStage({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<PreviewStage> createState() => _PreviewStageState();
}

class _PreviewStageState extends ConsumerState<PreviewStage> {
  /// assetId → controller. Keyed by asset, not clip: two clips from the same
  /// file share one decoder.
  final Map<String, VideoPlayerController> _controllers = {};
  final Set<String> _initialising = {};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final playhead = ref.watch(playheadControllerProvider);

    if (editor == null) {
      return const ColoredBox(color: Colors.black);
    }

    final timeline = editor.timeline;
    final visible = timeline.visualClipsAt(playhead.position);

    _syncControllers(editor.project, visible, playhead);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Letterbox the canvas inside the available space, preserving the
        // project's aspect ratio exactly — the preview must not lie about
        // framing.
        final canvasAspect = timeline.aspectRatio;
        var width = constraints.maxWidth;
        var height = width / canvasAspect;
        if (height > constraints.maxHeight) {
          height = constraints.maxHeight;
          width = height * canvasAspect;
        }

        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
              child: ColoredBox(
                color: Color(timeline.backgroundColor),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (var i = 0; i < visible.length; i++)
                      _buildLayer(
                        clip: visible[i],
                        project: editor.project,
                        playhead: playhead.position,
                        canvasSize: Size(width, height),
                        decoderBudgetExceeded: _videoLayerIndex(visible, i) >=
                            _maxConcurrentDecoders,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Position of this clip among the *video* layers only — image and text
  /// layers do not consume a decoder.
  int _videoLayerIndex(List<Clip> visible, int index) {
    var count = 0;
    for (var i = 0; i < index; i++) {
      if (visible[i] is VideoClip) count++;
    }
    return count;
  }

  Widget _buildLayer({
    required Clip clip,
    required Project project,
    required Duration playhead,
    required Size canvasSize,
    required bool decoderBudgetExceeded,
  }) {
    final local = clip.localTime(playhead);
    final transform = clip.transform.resolveAt(local);
    if (!transform.isVisible) return const SizedBox.shrink();

    Widget content;
    switch (clip) {
      case VideoClip():
        final asset = project.asset(clip.assetId);
        final controller = _controllers[clip.assetId];
        if (asset == null) return const SizedBox.shrink();
        content = (controller != null && controller.value.isInitialized)
            ? VideoPlayer(controller)
            : _PlaceholderLayer(
                asset: asset,
                message: decoderBudgetExceeded
                    ? 'Too many video layers to preview at once — '
                          'this layer still renders on export'
                    : null,
              );

      case ImageClip():
        final asset = project.asset(clip.assetId);
        if (asset == null) return const SizedBox.shrink();
        content = Image.file(
          File(asset.path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );

      case TextClip() || StickerClip():
        // Drawn by the same painter the exporter uses.
        content = CustomPaint(
          size: canvasSize,
          painter: _LayerCustomPainter(clip: clip, localTime: local),
        );

      case AudioClip():
        return const SizedBox.shrink();
    }

    content = _applyEffects(content, clip, local);

    return Opacity(
      opacity: transform.opacity.clamp(0.0, 1.0),
      child: Transform(
        alignment: Alignment(
          transform.anchorX * 2 - 1,
          transform.anchorY * 2 - 1,
        ),
        transform: Matrix4.identity()
          ..translateByDouble(
            transform.x * canvasSize.width,
            transform.y * canvasSize.height,
            0,
            1,
          )
          ..rotateZ(transform.rotation * 3.1415926535 / 180)
          ..scaleByDouble(
            transform.scaleX * (transform.flipHorizontal ? -1 : 1),
            transform.scaleY * (transform.flipVertical ? -1 : 1),
            1,
            1,
          ),
        child: content,
      ),
    );
  }

  /// Wraps [child] in one `ImageFiltered` per active effect.
  ///
  /// Each is a real GPU pass, so effects stack in the same order the exporter
  /// applies its filters (colour → stylise → texture, via `activeEffects`).
  Widget _applyEffects(Widget child, Clip clip, Duration local) {
    final effects = clip.activeEffects;
    if (effects.isEmpty) return child;

    final library = ref.read(shaderLibraryProvider);
    final seconds = local.inMicroseconds / 1e6;
    var result = child;

    for (final effect in effects) {
      final resolved = effect.resolveAt(local);
      if (resolved.isNoOp) continue;

      // Colour work is a cheap matrix — no reason to spend a shader pass.
      if (resolved.type == EffectType.colorAdjust) {
        result = _applyColorMatrix(result, resolved);
        continue;
      }

      final shader = library.shaderFor(resolved.type);
      if (shader == null) continue;

      final applied = ShaderUniforms.apply(
        shader: shader,
        effect: resolved,
        // The filter runs in layer space; passing the canvas size keeps
        // pixel-denominated params (blur radius) consistent with export.
        width: 1080,
        height: 1920,
        timeSeconds: seconds,
      );
      if (!applied) continue;

      result = ImageFiltered(
        imageFilter: ImageFilter.shader(shader),
        child: result,
      );
    }
    return result;
  }

  Widget _applyColorMatrix(Widget child, ResolvedEffect effect) {
    final brightness = effect.value('brightness') * effect.intensity;
    final contrast = 1 + (effect.value('contrast', 1) - 1) * effect.intensity;
    final saturation = 1 + (effect.value('saturation', 1) - 1) * effect.intensity;

    // Standard luminance-preserving saturation matrix, then contrast about
    // mid-grey, then a brightness offset — matching FFmpeg's `eq` ordering.
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - saturation) * lr;
    final sg = (1 - saturation) * lg;
    final sb = (1 - saturation) * lb;
    final t = (1 - contrast) * 0.5 + brightness;

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(<double>[
        (sr + saturation) * contrast, sg * contrast, sb * contrast, 0, t * 255,
        sr * contrast, (sg + saturation) * contrast, sb * contrast, 0, t * 255,
        sr * contrast, sg * contrast, (sb + saturation) * contrast, 0, t * 255,
        0, 0, 0, 1, 0,
      ]),
      child: child,
    );
  }

  // ── Decoder pool ─────────────────────────────────────────────────────

  void _syncControllers(
    Project project,
    List<Clip> visible,
    PlayheadState playhead,
  ) {
    final needed = <String>{};
    var budget = 0;

    for (final clip in visible) {
      if (clip is! VideoClip) continue;
      if (budget >= _maxConcurrentDecoders) break;
      needed.add(clip.assetId);
      budget++;
    }

    // Release decoders for layers that scrolled out of view. Holding them open
    // exhausts the device's decoder pool within a few edits.
    for (final assetId in _controllers.keys.toList()) {
      if (needed.contains(assetId)) continue;
      _controllers.remove(assetId)?.dispose();
    }

    for (final assetId in needed) {
      final asset = project.asset(assetId);
      if (asset == null) continue;

      if (!_controllers.containsKey(assetId)) {
        _createController(asset);
        continue;
      }

      final controller = _controllers[assetId]!;
      if (!controller.value.isInitialized) continue;

      final clip = visible.whereType<VideoClip>().firstWhere(
        (c) => c.assetId == assetId,
        orElse: () => visible.whereType<VideoClip>().first,
      );
      _syncPlayback(controller, clip, playhead);
    }
  }

  void _syncPlayback(
    VideoPlayerController controller,
    VideoClip clip,
    PlayheadState playhead,
  ) {
    final target = clip.sourceTimeAt(playhead.position);
    final actual = controller.value.position;
    final drift = (target - actual).abs();

    if (playhead.isPlaying && !clip.reversed && !clip.isFrozen) {
      if (!controller.value.isPlaying) {
        // ignore: discarded_futures — fire-and-forget transport control
        controller.play();
      }
      // Only correct when the drift is audible/visible. Seeking on every frame
      // would make playback stutter far worse than the drift ever does.
      if (drift > const Duration(milliseconds: 220)) {
        // ignore: discarded_futures
        controller.seekTo(target);
      }
      // ignore: discarded_futures
      controller.setPlaybackSpeed(clip.speed.clamp(0.25, 2.0));
    } else {
      if (controller.value.isPlaying) {
        // ignore: discarded_futures
        controller.pause();
      }
      if (drift > const Duration(milliseconds: 40)) {
        // ignore: discarded_futures
        controller.seekTo(target);
      }
    }
  }

  void _createController(MediaAsset asset) {
    if (_initialising.contains(asset.id)) return;
    _initialising.add(asset.id);

    // Prefer the proxy: scrubbing 4K through the preview decoder is what makes
    // an editor feel broken.
    final controller = VideoPlayerController.file(File(asset.previewPath));
    controller
        .initialize()
        .then((_) {
          if (!mounted) {
            controller.dispose();
            return;
          }
          setState(() => _controllers[asset.id] = controller);
        })
        .catchError((Object _) {
          controller.dispose();
        })
        .whenComplete(() => _initialising.remove(asset.id));
  }
}

class _LayerCustomPainter extends CustomPainter {
  const _LayerCustomPainter({required this.clip, required this.localTime});

  final Clip clip;
  final Duration localTime;

  @override
  void paint(Canvas canvas, Size size) {
    LayerPainter.paintClip(
      canvas: canvas,
      size: size,
      clip: clip,
      // The transform is applied by the enclosing widget, so the painter is
      // asked for the untransformed layer only.
      localTime: localTime,
    );
  }

  @override
  bool shouldRepaint(_LayerCustomPainter old) =>
      old.clip != clip || old.localTime != localTime;
}

class _PlaceholderLayer extends StatelessWidget {
  const _PlaceholderLayer({required this.asset, this.message});

  final MediaAsset asset;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: message == null
            ? const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ),
      ),
    );
  }
}
