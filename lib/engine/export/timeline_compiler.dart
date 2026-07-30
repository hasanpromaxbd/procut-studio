/// Compiles a [Project] into a [RenderPlan].
///
/// This is a pure function of (project, settings, workspace) — no I/O, no
/// FFmpeg, no device. That is what makes the export path unit-testable: the
/// tests assert on the generated filter graph directly.
///
/// ## Structure of the generated graph
///
/// ```
///   colour source ─────────────────────────► [base]      full canvas, full length
///   track 0 clips ─► trim/speed/fit/fx ─► xfade|concat ─► [t0]
///   track 1 clips ─► …                                  ─► [t1]
///   [base][t0] overlay ─► [c0]
///   [c0][t1]   overlay ─► [c1]  …                        ─► [vout]
///
///   audio clips ─► atrim/atempo/volume/afade/adelay ─► amix ─► [aout]
/// ```
///
/// Two things cannot be expressed in one graph and are lifted into pre-passes:
/// reversed clips (FFmpeg's `reverse` buffers the entire input) and text /
/// sticker layers (rasterised by Flutter so the export matches the preview
/// exactly rather than approximately).
library;

import 'package:path/path.dart' as p;

import '../../core/logging/app_logger.dart';
import '../../core/utils/math_utils.dart';
import '../../core/utils/time_utils.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/effect.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/keyframe.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/text_style_spec.dart';
import '../../domain/entities/timeline.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/transform2d.dart';
import '../../domain/entities/transition.dart';
import '../../domain/entities/voice_effect.dart';
import '../effects/effect_catalog.dart';
import '../effects/mask_compiler.dart';
import '../ffmpeg/filter_graph.dart';
import '../ffmpeg/hardware_encoder.dart';
import '../transitions/transition_catalog.dart';
import 'effect_automation.dart';
import 'render_plan.dart';

class TimelineCompiler {
  const TimelineCompiler();

  static const _log = Log('TimelineCompiler');

  RenderPlan compile({
    required Project project,
    required ExportSettings settings,
    required String workspaceDir,
    required String outputPath,
    required EncoderChoice encoder,
    required HardwareEncoderProbe encoderProbe,
    bool preferFastTransitions = false,
  }) {
    final timeline = project.timeline;
    final (outWidth, outHeight) = settings.dimensionsFor(
      timeline.width,
      timeline.height,
    );
    final fps = settings.fps;
    final duration = timeline.duration;
    final warnings = <String>[];

    final graph = FilterGraph();
    final inputs = <RenderInput>[];
    final rasterSteps = <RasterStep>[];
    final preRenderSteps = <PreRenderStep>[];
    final commandScripts = <CommandScript>[];

    // Asset path → input index. One `-i` per distinct file no matter how many
    // clips use it; FFmpeg demuxes it once and the trims split it out.
    final inputIndexByKey = <String, int>{};

    int registerInput(String key, RenderInput input) {
      final existing = inputIndexByKey[key];
      if (existing != null) return existing;
      final index = inputs.length;
      inputs.add(input);
      inputIndexByKey[key] = index;
      return index;
    }

    // ── 1. Base canvas ───────────────────────────────────────────────
    final baseLabel = graph.newLabel('base');
    graph.chain(outputs: [baseLabel]).then(
      Filters.colorSource(
        color: timeline.backgroundColor,
        width: outWidth,
        height: outHeight,
        duration: duration,
        fps: fps,
      ),
    );

    // ── 2. Visual tracks, bottom to top ──────────────────────────────
    final trackLabels = <String>[];
    for (final track in timeline.visualTracks) {
      if (track.isEmpty) continue;
      // Adjustment tracks carry no picture of their own — they are applied to
      // the composite after everything below has been stacked.
      if (track.type == TrackType.adjustment) continue;
      final label = _compileVisualTrack(
        graph: graph,
        track: track,
        project: project,
        settings: settings,
        outWidth: outWidth,
        outHeight: outHeight,
        fps: fps,
        timelineDuration: duration,
        workspaceDir: workspaceDir,
        registerInput: registerInput,
        rasterSteps: rasterSteps,
        preRenderSteps: preRenderSteps,
        commandScripts: commandScripts,
        warnings: warnings,
        preferFastTransitions: preferFastTransitions,
      );
      if (label != null) trackLabels.add(label);
    }

    // ── 3. Composite ─────────────────────────────────────────────────
    var currentVideo = baseLabel;
    for (final trackLabel in trackLabels) {
      final next = graph.newLabel('comp');
      graph
          .chain(inputs: [currentVideo, trackLabel], outputs: [next])
          .then(Filters.overlay(x: '0', y: '0', format: 'auto'));
      currentVideo = next;
    }

    // ── 3b. Adjustment layers ────────────────────────────────────────
    //
    // Applied to the composite rather than per clip, gated by `enable` so the
    // grade only affects the span the adjustment clip covers. This is the whole
    // difference between an adjustment layer and an effect on a clip.
    for (final track in timeline.visualTracks) {
      if (track.type != TrackType.adjustment || track.hidden) continue;

      for (final clip in track.clips) {
        if (!clip.enabled) continue;
        final filters = EffectCatalog.buildChain(
          clip.activeEffects.map((e) => e.resolveAt(Duration.zero)).toList(),
        );
        if (filters.isEmpty) continue;

        final gate =
            'between(t,${TimeUtils.toFfmpegSeconds(clip.start)},'
            '${TimeUtils.toFfmpegSeconds(clip.end)})';
        for (final filter in filters) {
          filter.set('enable', gate);
        }

        final next = graph.newLabel('adj');
        graph.chain(inputs: [currentVideo], outputs: [next]).thenAll(filters);
        currentVideo = next;
      }
    }

    // Final format conversion. yuv420p is the only chroma layout every Android
    // decoder and every social platform reliably accepts.
    final videoOut = graph.newLabel('vout');
    graph
        .chain(inputs: [currentVideo], outputs: [videoOut])
        .then(Filters.fps(fps))
        .then(Filter('format', {'pix_fmts': 'yuv420p'}))
        .then(Filters.setSar('1'));

    // ── 4. Audio ─────────────────────────────────────────────────────
    final audioOut = _compileAudio(
      graph: graph,
      project: project,
      settings: settings,
      timelineDuration: duration,
      registerInput: registerInput,
      warnings: warnings,
    );

    // ── 5. Output flags ──────────────────────────────────────────────
    final outputArgs = <String>[
      '-c:v', encoder.encoderName,
      ...encoderProbe.rateControlArgs(
        encoder,
        settings,
        width: outWidth,
        height: outHeight,
      ),
      ...encoderProbe.presetArgs(encoder),
      '-pix_fmt', 'yuv420p',
      '-r', '$fps',
      // HEVC in MP4 must be tagged hvc1 or QuickTime and iOS show black.
      if (settings.videoCodec == VideoCodec.hevc) ...['-tag:v', settings.videoCodec.tag],
      if (audioOut != null) ...[
        '-c:a', settings.audioCodec.encoder,
        '-b:a', '${settings.audioBitrateKbps}k',
        '-ar', '${settings.audioSampleRate}',
        '-ac', '2',
      ] else
        '-an',
      // Moves the index to the front so the file starts playing before it has
      // fully downloaded — required by most upload targets.
      '-movflags', '+faststart',
      '-f', settings.container == ExportContainer.mov ? 'mov' : 'mp4',
    ];

    final missing = graph.validate();
    if (missing.isNotEmpty) {
      _log.e('graph references undefined labels', fields: {'labels': missing});
      warnings.add('Internal graph error: unresolved ${missing.join(', ')}.');
    }

    final plan = RenderPlan(
      inputs: inputs,
      filterGraph: graph.build(),
      outputArgs: outputArgs,
      outputPath: outputPath,
      duration: duration,
      width: outWidth,
      height: outHeight,
      fps: fps,
      rasterSteps: rasterSteps,
      preRenderSteps: preRenderSteps,
      commandScripts: commandScripts,
      videoOutLabel: videoOut,
      audioOutLabel: audioOut,
      warnings: warnings,
    );
    _log.i('compiled', fields: {'plan': plan.toString()});
    return plan;
  }

  // ───────────────────────────────────────────────────────────────────
  // Visual tracks
  // ───────────────────────────────────────────────────────────────────

  String? _compileVisualTrack({
    required FilterGraph graph,
    required Track track,
    required Project project,
    required ExportSettings settings,
    required int outWidth,
    required int outHeight,
    required int fps,
    required Duration timelineDuration,
    required String workspaceDir,
    required int Function(String key, RenderInput input) registerInput,
    required List<RasterStep> rasterSteps,
    required List<PreRenderStep> preRenderSteps,
    required List<CommandScript> commandScripts,
    required List<String> warnings,
    required bool preferFastTransitions,
  }) {
    // Each track becomes one full-length stream with transparent gaps, so the
    // composite step is a plain overlay chain with no per-clip `enable=`
    // expressions to get wrong.
    final segments = <_Segment>[];
    var cursor = Duration.zero;

    for (final clip in track.clips) {
      if (!clip.enabled) continue;

      // Gap before this clip → transparent filler.
      final overlap = _incomingOverlapFor(track, clip);
      final visualStart = clip.start + overlap;
      if (visualStart > cursor) {
        segments.add(
          _Segment(
            label: _transparentSegment(
              graph,
              outWidth,
              outHeight,
              visualStart - cursor,
              fps,
            ),
            duration: visualStart - cursor,
          ),
        );
        cursor = visualStart;
      }

      final segment = _compileVisualClip(
        graph: graph,
        clip: clip,
        project: project,
        outWidth: outWidth,
        outHeight: outHeight,
        fps: fps,
        workspaceDir: workspaceDir,
        registerInput: registerInput,
        rasterSteps: rasterSteps,
        preRenderSteps: preRenderSteps,
        commandScripts: commandScripts,
        warnings: warnings,
      );
      if (segment == null) continue;

      segments.add(segment);
      cursor = clip.end;
    }

    if (segments.isEmpty) return null;

    // Tail filler so every track is exactly the timeline length; `overlay`
    // stops compositing when its second input ends, which would otherwise clip
    // lower tracks short.
    if (cursor < timelineDuration) {
      segments.add(
        _Segment(
          label: _transparentSegment(
            graph,
            outWidth,
            outHeight,
            timelineDuration - cursor,
            fps,
          ),
          duration: timelineDuration - cursor,
        ),
      );
    }

    // Fold the segments left, choosing concat or xfade per join.
    var accumulator = segments.first.label;
    var accumulatedLength = segments.first.duration;

    for (var i = 1; i < segments.length; i++) {
      final segment = segments[i];
      final next = graph.newLabel('trk');
      final transition = segments[i - 1].outTransition;

      if (transition != null && transition.isActive) {
        // `offset` is measured from the start of the *accumulated* stream, and
        // is where the blend begins — not where the second clip starts.
        final offset = accumulatedLength - transition.duration;
        graph.chain(inputs: [accumulator, segment.label], outputs: [next]).then(
          TransitionCatalog.buildXfade(
            transition,
            offset < Duration.zero ? Duration.zero : offset,
            preferFastApproximation: preferFastTransitions,
          ),
        );
        accumulatedLength =
            accumulatedLength + segment.duration - transition.duration;
        if (TransitionCatalog.isExpensive(transition) && !preferFastTransitions) {
          warnings.add(
            '"${transition.type.id}" is rendered per-pixel and will slow the '
            'export down. Switch to fast transitions to trade exactness for speed.',
          );
        }
      } else {
        graph
            .chain(inputs: [accumulator, segment.label], outputs: [next])
            .then(Filters.concat(segments: 2, v: 1, a: 0));
        accumulatedLength += segment.duration;
      }
      accumulator = next;
    }

    return accumulator;
  }

  /// The overlap this clip inherits from the preceding clip's transition.
  Duration _incomingOverlapFor(Track track, Clip clip) {
    final index = track.indexOfClip(clip.id);
    if (index <= 0) return Duration.zero;
    final previous = track.clips[index - 1];
    final transition = previous.outTransition;
    if (transition == null || !transition.isActive) return Duration.zero;
    return transition.overlap;
  }

  String _transparentSegment(
    FilterGraph graph,
    int width,
    int height,
    Duration duration,
    int fps,
  ) {
    final label = graph.newLabel('gap');
    graph
        .chain(outputs: [label])
        .then(
          Filters.colorSource(
            color: 0x00000000,
            width: width,
            height: height,
            duration: duration,
            fps: fps,
          ),
        )
        .then(Filter('format', {'pix_fmts': 'yuva420p'}));
    return label;
  }

  _Segment? _compileVisualClip({
    required FilterGraph graph,
    required Clip clip,
    required Project project,
    required int outWidth,
    required int outHeight,
    required int fps,
    required String workspaceDir,
    required int Function(String key, RenderInput input) registerInput,
    required List<RasterStep> rasterSteps,
    required List<PreRenderStep> preRenderSteps,
    required List<CommandScript> commandScripts,
    required List<String> warnings,
  }) {
    final label = graph.newLabel('seg');
    final transition = clip.outTransition;

    switch (clip) {
      case VideoClip():
        final asset = project.asset(clip.assetId);
        if (asset == null) {
          warnings.add('A clip references missing media and was skipped.');
          return null;
        }

        // Stabilisation is two-pass by nature: vidstabdetect writes a motion
        // file that vidstabtransform then consumes. Neither can happen inline.
        final stabilise = clip.activeEffects
            .where((e) => e.type == EffectType.stabilise)
            .firstOrNull;

        // A reversed clip is pre-rendered: `reverse` needs the whole segment in
        // memory, so doing it inline would blow up on a long clip.
        final String sourcePath;
        final Duration sourceIn;
        if (clip.reversed) {
          final step = _reversePreRender(
            clip: clip,
            asset: asset,
            workspaceDir: workspaceDir,
            fps: fps,
          );
          preRenderSteps.add(step);
          sourcePath = step.outputPath;
          sourceIn = Duration.zero;
        } else {
          sourcePath = asset.path;
          sourceIn = clip.sourceIn;
        }

        // Keyed by path alone so the audio pass reuses this same `-i`.
        // Registering video and audio separately opened the file twice, which
        // costs a whole extra demuxer and decoder for no benefit.
        var effectivePath = sourcePath;
        var effectiveIn = sourceIn;
        if (stabilise != null) {
          final steps = _stabilisePreRender(
            clip: clip,
            sourcePath: sourcePath,
            sourceIn: sourceIn,
            workspaceDir: workspaceDir,
            smoothing: stabilise.param('smoothing', fallback: 10).round(),
          );
          preRenderSteps.addAll(steps);
          effectivePath = steps.last.outputPath;
          // The pre-render already trimmed to the clip's window.
          effectiveIn = Duration.zero;
        }

        final index = registerInput(
          'file:$effectivePath',
          RenderInput(path: effectivePath, label: 'media:$effectivePath'),
        );

        final chain = graph.chain(inputs: ['$index:v'], outputs: [label]);

        if (clip.isFrozen) {
          chain.thenAll(
            Filters.freezeFrame(clip.freezeFrameAt!, clip.duration, fps),
          );
        } else {
          chain
              .then(
                Filters.trim(
                  effectiveIn,
                  effectiveIn + clip.sourceDuration,
                ),
              )
              .then(Filters.resetPts());
          if (clip.hasSpeedRamp) {
            // `setpts` cannot express the integral of an arbitrary eased
            // curve, so the ramp is approximated by constant-rate segments.
            // 24 is smooth to the eye and keeps the graph manageable; more
            // segments cost graph size, not quality, past this point.
            warnings.add(
              'A speed ramp is rendered as stepped segments; very long ramps '
              'may show slight stepping.',
            );
            chain.then(Filters.videoSpeed(clip.speed));
          } else if (clip.isSpeedAltered) {
            chain.then(Filters.videoSpeed(clip.speed));
          }
        }

        chain.then(Filters.fps(fps));
        _appendGeometry(chain, clip.transform, asset, outWidth, outHeight);
        _collectAutomation(
          _appendEffects(chain, clip, workspaceDir),
          commandScripts,
          warnings,
        );
        chain.then(Filter('format', {'pix_fmts': 'yuva420p'}));
        chain.thenAll(MaskCompiler.build(clip.mask.resolveAt(Duration.zero)));
        _appendOpacity(chain, clip.transform);

        return _Segment(
          label: label,
          duration: clip.duration,
          outTransition: transition,
        );

      case ImageClip():
        final asset = project.asset(clip.assetId);
        if (asset == null) {
          warnings.add('An image clip references missing media and was skipped.');
          return null;
        }
        final index = registerInput(
          'img:${asset.path}:${clip.id}',
          RenderInput(
            path: asset.path,
            // `-loop 1` turns a still into a stream; `-t` bounds it, otherwise
            // the loop is infinite and the render never terminates.
            leadingArgs: [
              '-loop', '1',
              '-t', TimeUtils.toFfmpegSeconds(clip.duration),
            ],
            label: 'image:${clip.id}',
          ),
        );

        final chain = graph.chain(inputs: ['$index:v'], outputs: [label]);
        chain.then(Filters.fps(fps));

        // A still with animated scale/position is a camera move (Ken Burns),
        // and `zoompan` is the filter built for exactly that. The static
        // geometry path reads `.staticValue` and would freeze the move.
        if (_hasCameraMove(clip.transform)) {
          _appendCameraMove(
            chain,
            clip,
            fps: fps,
            outWidth: outWidth,
            outHeight: outHeight,
            warnings: warnings,
          );
        } else {
          _appendGeometry(chain, clip.transform, asset, outWidth, outHeight);
        }
        _collectAutomation(
          _appendEffects(chain, clip, workspaceDir),
          commandScripts,
          warnings,
        );
        chain.then(Filter('format', {'pix_fmts': 'yuva420p'}));
        chain.thenAll(MaskCompiler.build(clip.mask.resolveAt(Duration.zero)));
        _appendOpacity(chain, clip.transform);

        return _Segment(
          label: label,
          duration: clip.duration,
          outTransition: transition,
        );

      case TextClip():
      case StickerClip():
        // Rasterised by Flutter so the export is identical to what the user
        // composed, rather than an approximation via `drawtext`.
        final animated = clip is TextClip
            ? (clip.animationIn != TextAnimation.none ||
                clip.animationOut != TextAnimation.none ||
                clip.transform.isAnimated)
            : clip.transform.isAnimated;

        final frameCount = animated
            ? MathUtils.clampInt(
                (clip.duration.inMicroseconds * fps / 1e6).round(),
                1,
                fps * 600,
              )
            : 1;

        final rasterPath = animated
            ? p.join(workspaceDir, 'layer_${clip.id}')
            : p.join(workspaceDir, 'layer_${clip.id}.png');

        rasterSteps.add(
          RasterStep(
            id: 'raster_${clip.id}',
            clipId: clip.id,
            outputPath: rasterPath,
            isSequence: animated,
            frameCount: frameCount,
            description: clip is TextClip ? 'Rendering title' : 'Rendering sticker',
          ),
        );

        final index = registerInput(
          'raster:${clip.id}',
          RenderInput(
            path: animated ? p.join(rasterPath, '%05d.png') : rasterPath,
            leadingArgs: animated
                ? ['-framerate', '$fps']
                : [
                    '-loop', '1',
                    '-t', TimeUtils.toFfmpegSeconds(clip.duration),
                  ],
            label: 'layer:${clip.id}',
          ),
        );

        final chain = graph.chain(inputs: ['$index:v'], outputs: [label]);
        chain
            .then(Filters.fps(fps))
            .then(
              Filter('scale', {
                'w': outWidth,
                'h': outHeight,
                'flags': 'bicubic',
              }),
            )
            .then(Filter('format', {'pix_fmts': 'yuva420p'}));

        return _Segment(
          label: label,
          duration: clip.duration,
          outTransition: transition,
        );

      case CompoundClip():
        if (clip.innerClips.isEmpty) return null;

        // The members compile through the exact machinery a real track uses —
        // transitions between them included — into one stream the length of
        // the compound's window. Content past the window is simply not shown,
        // which is what makes ungrouping lossless.
        final innerLabel = _compileVisualTrack(
          graph: graph,
          track: Track(
            id: 'cmp_${clip.id}',
            type: TrackType.video,
            clips: clip.innerClips,
          ),
          project: project,
          settings: const ExportSettings(),
          outWidth: outWidth,
          outHeight: outHeight,
          fps: fps,
          timelineDuration: clip.duration,
          workspaceDir: workspaceDir,
          registerInput: registerInput,
          rasterSteps: rasterSteps,
          preRenderSteps: preRenderSteps,
          commandScripts: commandScripts,
          warnings: warnings,
          preferFastTransitions: false,
        );
        if (innerLabel == null) return null;

        // The compound's own dressing applies to the composed result, the
        // way it would to any single clip.
        final chain = graph.chain(inputs: [innerLabel], outputs: [label]);
        var dressed = false;
        final scale = clip.transform.scaleX.staticValue;
        if ((scale - 1).abs() > 0.001) {
          chain.then(
            Filter('scale', {
              'w': 'iw*${FilterGraph.formatDouble(scale)}',
              'h':
                  'ih*${FilterGraph.formatDouble(clip.transform.scaleY.staticValue)}',
              'flags': 'bicubic',
            }),
          );
          chain.thenAll(Filters.scaleToFit(outWidth, outHeight));
          dressed = true;
        }
        if (clip.transform.flipHorizontal) {
          chain.then(Filters.hflip());
          dressed = true;
        }
        if (clip.transform.flipVertical) {
          chain.then(Filters.vflip());
          dressed = true;
        }
        _collectAutomation(
          _appendEffects(chain, clip, workspaceDir),
          commandScripts,
          warnings,
        );
        final maskFilters = MaskCompiler.build(
          clip.mask.resolveAt(Duration.zero),
        );
        chain.thenAll(maskFilters);
        _appendOpacity(chain, clip.transform);
        if (!dressed &&
            chain.filters.isEmpty) {
          // An empty chain is an FFmpeg parse error; `null` is a passthrough.
          chain.then(Filter('null'));
        }

        return _Segment(
          label: label,
          duration: clip.duration,
          outTransition: transition,
        );

      case AudioClip():
        return null; // handled by the audio pass
    }
  }

  /// vidstabdetect writes a motion vector file; vidstabtransform consumes it.
  /// Two `PreRenderStep`s, reusing the machinery built for reversed clips.
  List<PreRenderStep> _stabilisePreRender({
    required VideoClip clip,
    required String sourcePath,
    required Duration sourceIn,
    required String workspaceDir,
    required int smoothing,
  }) {
    final vectors = p.join(workspaceDir, 'stab_${clip.id}.trf');
    final output = p.join(workspaceDir, 'stab_${clip.id}.mp4');
    final start = TimeUtils.toFfmpegSeconds(sourceIn);
    final length = TimeUtils.toFfmpegSeconds(clip.sourceDuration);

    // Built outside the argument lists: adjacent string literals inside a list
    // are indistinguishable from a forgotten comma, which is exactly the bug
    // the lint is guarding against.
    final detectFilter =
        'vidstabdetect=shakiness=6:accuracy=12'
        ':result=${RenderPlan.quoteArg(vectors)}';
    final transformFilter =
        'vidstabtransform=input=${RenderPlan.quoteArg(vectors)}'
        ':smoothing=$smoothing:crop=black:zoom=0:optzoom=1'
        ',unsharp=5:5:0.8';

    return [
      PreRenderStep(
        id: 'stabdetect_${clip.id}',
        description: 'Analysing camera shake',
        outputPath: vectors,
        estimatedDuration: clip.sourceDuration,
        weight: 1.5,
        command: [
          '-y', '-hide_banner',
          '-ss', start, '-t', length,
          '-i', RenderPlan.quoteArg(sourcePath),
          '-vf', detectFilter,
          '-f', 'null', '-',
        ].join(' '),
      ),
      PreRenderStep(
        id: 'stabtransform_${clip.id}',
        description: 'Stabilising',
        outputPath: output,
        estimatedDuration: clip.sourceDuration,
        weight: 2.0,
        command: [
          '-y', '-hide_banner',
          '-ss', start, '-t', length,
          '-i', RenderPlan.quoteArg(sourcePath),
          '-vf', transformFilter,
          '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18',
          '-pix_fmt', 'yuv420p',
          '-c:a', 'copy',
          RenderPlan.quoteArg(output),
        ].join(' '),
      ),
    ];
  }

  PreRenderStep _reversePreRender({
    required VideoClip clip,
    required MediaAsset asset,
    required String workspaceDir,
    required int fps,
  }) {
    final output = p.join(workspaceDir, 'reversed_${clip.id}.mp4');
    final start = TimeUtils.toFfmpegSeconds(clip.sourceIn);
    final length = TimeUtils.toFfmpegSeconds(clip.sourceDuration);

    // `-ss` before `-i` seeks by keyframe (fast); the trim is then exact
    // because we re-encode anyway. Encoding to an intermediate at CRF 18 keeps
    // the reverse pass from becoming the quality bottleneck.
    return PreRenderStep(
      id: 'reverse_${clip.id}',
      description: 'Reversing clip',
      outputPath: output,
      estimatedDuration: clip.sourceDuration,
      weight: 2.0,
      command: [
        '-y', '-hide_banner',
        '-ss', start,
        '-t', length,
        '-i', RenderPlan.quoteArg(asset.path),
        '-vf', 'reverse,fps=$fps',
        '-af', 'areverse',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac',
        RenderPlan.quoteArg(output),
      ].join(' '),
    );
  }

  static bool _hasCameraMove(Transform2D transform) =>
      transform.scaleX.isAnimated ||
      transform.scaleY.isAnimated ||
      transform.x.isAnimated ||
      transform.y.isAnimated;

  /// Renders an animated still through `zoompan`.
  ///
  /// The frame is first fitted onto a canvas at 2× output size — zoompan
  /// samples its crop window from the input, and a window cut from a
  /// same-size frame goes visibly soft by 1.2×. The window then travels
  /// between the transform's endpoint values on a smoothstep ramp, which is
  /// the preview's easeInOut to within a hair.
  ///
  /// Endpoints only: a hand-built multi-keyframe move on a still is
  /// approximated by its first and last values, and says so, rather than
  /// silently freezing the way the static path did.
  void _appendCameraMove(
    FilterChain chain,
    ImageClip clip, {
    required int fps,
    required int outWidth,
    required int outHeight,
    required List<String> warnings,
  }) {
    final transform = clip.transform;
    final frames = MathUtils.clampInt(
      (clip.duration.inMicroseconds * fps / 1e6).round(),
      2,
      fps * 600,
    );

    if ([transform.scaleX, transform.x, transform.y]
        .any((c) => c.keyframes.length > 2)) {
      warnings.add(
        'A still\u2019s camera move has more than two keyframes; the export '
        'plays it as one move between the first and last.',
      );
    }

    double at(AnimatableDouble channel, Duration time) => channel.valueAt(time);
    final end = clip.duration;

    final zoomFrom = at(transform.scaleX, Duration.zero).clamp(1.0, 10.0);
    final zoomTo = at(transform.scaleX, end).clamp(1.0, 10.0);
    final xFrom = at(transform.x, Duration.zero);
    final xTo = at(transform.x, end);
    final yFrom = at(transform.y, Duration.zero);
    final yTo = at(transform.y, end);

    // Progress over output frames, eased. `on` counts output frames, so this
    // is exact regardless of the input's own timing.
    final progress =
        'st(0,min(on/${frames - 1},1))*0+ld(0)*ld(0)*(3-2*ld(0))';

    String ramp(double from, double to) => (to - from).abs() < 1e-9
        ? FilterGraph.formatDouble(from)
        : '${FilterGraph.formatDouble(from)}+'
              '(${FilterGraph.formatDouble(to - from)})*($progress)';

    // Oversampled fit, then the moving window. A positive transform.x moves
    // the image right, which moves the crop window left — hence the minus.
    chain
      ..thenAll(Filters.scaleToFit(outWidth * 2, outHeight * 2))
      ..then(
        Filter('zoompan', {
          'z': ramp(zoomFrom, zoomTo),
          'x': 'iw/2-(iw/zoom/2)-(${ramp(xFrom, xTo)})*iw',
          'y': 'ih/2-(ih/zoom/2)-(${ramp(yFrom, yTo)})*ih',
          'd': 1,
          's': '${outWidth}x$outHeight',
          'fps': fps,
        }),
      );
  }

  /// Crop → flip → rotate → fit into the canvas. Order matters: cropping after
  /// a rotation would cut the wrong region.
  void _appendGeometry(
    FilterChain chain,
    Transform2D transform,
    MediaAsset asset,
    int outWidth,
    int outHeight,
  ) {
    if (!transform.crop.isNone) {
      chain.then(
        Filters.crop(
          left: transform.crop.left,
          top: transform.crop.top,
          right: transform.crop.right,
          bottom: transform.crop.bottom,
        ),
      );
    }
    if (transform.flipHorizontal) chain.then(Filters.hflip());
    if (transform.flipVertical) chain.then(Filters.vflip());

    // Container rotation must be applied explicitly: we decode with
    // `-noautorotate` semantics inside filter graphs, so portrait phone
    // footage would otherwise land on its side.
    if (asset.rotationDegrees != 0) {
      chain.thenAll(Filters.rotateQuarter(asset.rotationDegrees ~/ 90));
    }

    final rotation = transform.rotation.staticValue % 360;
    if (rotation.abs() > 0.01) {
      if (rotation % 90 == 0) {
        chain.thenAll(Filters.rotateQuarter((rotation ~/ 90).toInt()));
      } else {
        chain.then(Filters.rotate(rotation));
      }
    }

    final scale = transform.scaleX.staticValue;
    if ((scale - 1).abs() > 0.001) {
      chain.then(
        Filter('scale', {
          'w': 'iw*${FilterGraph.formatDouble(scale)}',
          'h': 'ih*${FilterGraph.formatDouble(transform.scaleY.staticValue)}',
          'flags': 'bicubic',
        }),
      );
    }

    chain.thenAll(Filters.scaleToFit(outWidth, outHeight));
  }

  /// Appends the clip's effect filters, wiring up `sendcmd` automation when
  /// any of them are keyframed.
  EffectAutomation _appendEffects(
    FilterChain chain,
    Clip clip,
    String workspaceDir,
  ) {
    final effects = clip.activeEffects;
    if (effects.isEmpty) {
      return const EffectAutomation(script: null, staticEffectTypes: []);
    }

    // Animated effects are built at their peak so the filter instance survives
    // into the graph — see EffectAutomationCompiler.representativeResolution.
    final resolved = effects
        .map(
          (e) => e.isAnimated
              ? EffectAutomationCompiler.representativeResolution(
                  e,
                  clip.duration,
                )
              : e.resolveAt(Duration.zero),
        )
        .toList();

    final filters = EffectCatalog.buildChain(resolved);

    final automation = EffectAutomationCompiler.compile(
      clip: clip,
      scriptPath: p.join(workspaceDir, 'fx_${clip.id}.cmd'),
    );

    if (automation.hasScript) {
      EffectAutomationCompiler.applyLabels(filters, effects);
      // `sendcmd` only reaches filters downstream of it in the same chain.
      chain.then(
        Filter('sendcmd', {
          'f': FilterGraph.escapePath(automation.script!.path),
        }),
      );
    }

    chain.thenAll(filters);
    return automation;
  }

  /// Files the generated script and warns about effects that could not be
  /// animated on export.
  void _collectAutomation(
    EffectAutomation automation,
    List<CommandScript> scripts,
    List<String> warnings,
  ) {
    if (automation.hasScript) scripts.add(automation.script!);

    for (final type in automation.staticEffectTypes) {
      final label = EffectCatalog.specFor(type)?.label ?? type.id;
      final warning =
          '"$label" is keyframed, but its FFmpeg filter cannot be changed '
          'mid-render — it will export at its first-frame value.';
      if (!warnings.contains(warning)) warnings.add(warning);
    }
  }

  void _appendOpacity(FilterChain chain, Transform2D transform) {
    final opacity = transform.opacity.staticValue;
    if (opacity >= 0.999) return;
    // colorchannelmixer scales the alpha channel, which `overlay` then honours.
    chain.then(
      Filter('colorchannelmixer', {
        'aa': FilterGraph.formatDouble(opacity.clamp(0.0, 1.0)),
      }),
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // Audio
  // ───────────────────────────────────────────────────────────────────

  String? _compileAudio({
    required FilterGraph graph,
    required Project project,
    required ExportSettings settings,
    required Duration timelineDuration,
    required int Function(String key, RenderInput input) registerInput,
    required List<String> warnings,
  }) {
    final timeline = project.timeline;
    // Stems are collected per track, not into one flat list, because ducking
    // needs a whole track as the key signal — one clip's stem is not "the
    // voice", the voice track is.
    final stemsByTrack = <String, List<String>>{};

    for (final track in timeline.tracks) {
      if (!timeline.isTrackAudible(track)) continue;

      // Grouped members carry their audio with them: each inner clip joins
      // the mix at the compound's offset, clipped to its window.
      final audible = <Clip>[
        for (final clip in track.clips)
          if (clip is CompoundClip) ...[
            if (clip.enabled)
              for (final inner in clip.innerClips)
                if (inner.enabled && inner.start < clip.duration)
                  inner.copyWithBase(start: clip.start + inner.start),
          ] else
            clip,
      ];

      for (final clip in audible) {
        if (!clip.enabled) continue;

        final _AudioSource? source = switch (clip) {
          AudioClip() => _AudioSource(
            assetId: clip.assetId,
            sourceIn: clip.sourceIn,
            sourceDuration: clip.sourceDuration,
            start: clip.start,
            duration: clip.duration,
            speed: clip.speed,
            preservePitch: clip.preservePitch,
            pitchSemitones: clip.pitchSemitones,
            gain: clip.volume.staticValue * track.volume,
            fadeIn: clip.fadeIn,
            fadeOut: clip.fadeOut,
            equalizer: clip.equalizer,
            reversed: clip.reversed,
            voiceEffect: clip.voiceEffect,
          ),
          VideoClip() when !clip.muted && !clip.isFrozen => _AudioSource(
            assetId: clip.assetId,
            sourceIn: clip.sourceIn,
            sourceDuration: clip.sourceDuration,
            start: clip.start,
            duration: clip.duration,
            speed: clip.speed,
            preservePitch: true,
            pitchSemitones: 0,
            gain: clip.volume.staticValue * track.volume,
            fadeIn: clip.audioFadeIn,
            fadeOut: clip.audioFadeOut,
            equalizer: null,
            reversed: clip.reversed,
            voiceEffect: VoiceEffect.none,
          ),
          _ => null,
        };
        if (source == null) continue;

        final asset = project.asset(source.assetId);
        if (asset == null || !asset.hasAudioStream) continue;

        final index = registerInput(
          'file:${asset.path}',
          RenderInput(path: asset.path, label: 'media:${asset.path}'),
        );

        final label = graph.newLabel('a');
        final chain = graph.chain(inputs: ['$index:a'], outputs: [label]);

        chain
            .then(
              Filters.atrim(
                source.sourceIn,
                source.sourceIn + source.sourceDuration,
              ),
            )
            .then(Filters.resetAudioPts());

        if (source.reversed) chain.then(Filters.reverseAudio());

        if ((source.speed - 1.0).abs() > 1e-6) {
          if (source.preservePitch) {
            chain.thenAll(Filters.audioSpeed(source.speed));
          } else {
            // Changing the sample rate shifts pitch with speed, the way a tape
            // machine does.
            chain
              ..then(
                Filter('asetrate')
                  ..arg(
                    '${(settings.audioSampleRate * source.speed).round()}',
                  ),
              )
              ..then(Filter('aresample')..arg('${settings.audioSampleRate}'));
          }
        }

        final totalPitch =
            source.pitchSemitones + source.voiceEffect.semitones;
        if (totalPitch.abs() > 0.01) {
          chain.thenAll(
            Filters.pitchShift(
              totalPitch,
              sampleRate: settings.audioSampleRate,
            ),
          );
        }
        chain.thenAll(Filters.voiceEffect(source.voiceEffect));

        final eq = source.equalizer;
        if (eq != null && !eq.isFlat) {
          for (var band = 0; band < EqualizerSettings.frequencies.length; band++) {
            final gain = eq.gains[band];
            if (gain.abs() < 0.01) continue;
            chain.then(
              Filter('equalizer', {
                'f': EqualizerSettings.frequencies[band],
                't': 'q',
                'w': 1.2,
                'g': FilterGraph.formatDouble(gain),
              }),
            );
          }
        }

        if ((source.gain - 1.0).abs() > 1e-6) {
          chain.then(Filters.volume(source.gain));
        }
        if (source.fadeIn > Duration.zero) {
          chain.then(Filters.audioFadeIn(Duration.zero, source.fadeIn));
        }
        if (source.fadeOut > Duration.zero) {
          chain.then(
            Filters.audioFadeOut(
              source.duration - source.fadeOut,
              source.fadeOut,
            ),
          );
        }

        // Position the stem on the timeline. `adelay` pads the head with
        // silence; `apad` extends the tail so every amix input is the same
        // length and the mix does not end early.
        if (source.start > Duration.zero) {
          chain.then(Filters.audioDelay(source.start));
        }
        chain
          ..then(
            Filter('aformat', {
              'sample_fmts': 'fltp',
              'sample_rates': settings.audioSampleRate,
              'channel_layouts': 'stereo',
            }),
          )
          ..then(Filters.audioPad(timelineDuration));

        stemsByTrack.putIfAbsent(track.id, () => []).add(label);
      }
    }

    final totalStems = stemsByTrack.values.fold(0, (a, b) => a + b.length);
    if (totalStems == 0) return null;

    // One label per track, so ducking has something whole to work with.
    final trackMix = <String, String>{
      for (final entry in stemsByTrack.entries)
        entry.key: _mergeStems(graph, entry.value),
    };

    final ducked = _applyDucking(
      graph: graph,
      timeline: timeline,
      trackMix: trackMix,
      warnings: warnings,
    );

    final stemLabels = ducked.values.toList();
    final mixed = graph.newLabel('aout');
    final chain = graph.chain(inputs: stemLabels, outputs: [mixed]);
    if (stemLabels.length > 1) {
      chain.then(Filters.mixAudio(stemLabels.length));
    }
    chain
      ..then(Filters.atrim(Duration.zero, timelineDuration))
      ..then(Filters.resetAudioPts());

    if (settings.normalizeLoudness) {
      // Single-pass loudnorm: it adapts as it goes rather than measuring the
      // whole mix first, which can breathe a little on very dynamic audio.
      // The honest two-pass variant needs the finished mix before the encode
      // starts — a second full render. For −14 LUFS platform delivery the
      // single pass lands within a fraction of an LU, and the settings sheet
      // says what it does rather than overpromising.
      chain.then(
        Filter('loudnorm', {
          'I': -14,
          'TP': -1.5,
          'LRA': 11,
        }),
      );
      // loudnorm resamples internally to 192 kHz; bring the stream back to
      // the container's rate or the encode fails on a rate mismatch.
      chain.then(Filter('aresample')..arg('${settings.audioSampleRate}'));
    }

    if (totalStems > 8) {
      warnings.add(
        'This project mixes $totalStems audio sources; '
        'the export will take longer than usual.',
      );
    }
    return mixed;
  }

  /// Collapses a track's clip stems into one label.
  static String _mergeStems(FilterGraph graph, List<String> stems) {
    if (stems.length == 1) return stems.single;
    final label = graph.newLabel('atrk');
    graph
        .chain(inputs: stems, outputs: [label])
        .then(Filters.mixAudio(stems.length));
    return label;
  }

  /// Rewires ducked tracks through `sidechaincompress`.
  ///
  /// The key track's audio has to be heard *and* used as the trigger, so it is
  /// split first: one branch drives the compressor, the other stays in the
  /// mix. Forgetting the split is the classic mistake here — the voice
  /// disappears from the export and only the ducking survives.
  static Map<String, String> _applyDucking({
    required FilterGraph graph,
    required Timeline timeline,
    required Map<String, String> trackMix,
    required List<String> warnings,
  }) {
    final duckers = <Track>[
      for (final track in timeline.tracks)
        if (track.isDucked && trackMix.containsKey(track.id)) track,
    ];
    if (duckers.isEmpty) return trackMix;

    final result = Map<String, String>.of(trackMix);

    // How many key branches each key track must produce: one per track that
    // ducks under it, plus one that stays audible.
    final keyDemand = <String, int>{};
    for (final track in duckers) {
      final key = track.ducking!.keyTrackId;
      if (!trackMix.containsKey(key) || key == track.id) continue;
      keyDemand[key] = (keyDemand[key] ?? 0) + 1;
    }

    final keyBranches = <String, List<String>>{};
    for (final entry in keyDemand.entries) {
      // One branch per ducker, plus one that stays audible in the mix.
      final branches = [
        for (var i = 0; i <= entry.value; i++) graph.newLabel('akey'),
      ];
      graph
          .chain(inputs: [trackMix[entry.key]!], outputs: branches)
          .then(Filter('asplit')..arg('${branches.length}'));

      result[entry.key] = branches.last;
      keyBranches[entry.key] = branches.sublist(0, branches.length - 1);
    }

    for (final track in duckers) {
      final duck = track.ducking!;
      final key = duck.keyTrackId;
      if (key == track.id) {
        warnings.add(
          'The ${track.displayName} track is set to duck under itself; '
          'ducking was skipped for it.',
        );
        continue;
      }
      final branches = keyBranches[key];
      if (branches == null || branches.isEmpty) {
        warnings.add(
          'The ${track.displayName} track ducks under a track with no audio; '
          'ducking was skipped for it.',
        );
        continue;
      }

      final out = graph.newLabel('aduck');
      graph
          .chain(inputs: [result[track.id]!, branches.removeAt(0)], outputs: [out])
          .then(Filters.sidechainCompress(duck));
      result[track.id] = out;
    }

    return result;
  }
}

/// One rendered piece of a track, plus the transition that joins it to the
/// previous piece.
class _Segment {
  const _Segment({
    required this.label,
    required this.duration,
    this.outTransition,
  });

  final String label;
  final Duration duration;

  /// The transition leaving this segment into the next one. The fold in
  /// [TimelineCompiler._compileVisualTrack] reads it from the *previous*
  /// segment when deciding how to join.
  final Transition? outTransition;
}

/// Normalised view of "a thing that produces audio", so video and audio clips
/// share one code path in the mixer.
class _AudioSource {
  const _AudioSource({
    required this.assetId,
    required this.sourceIn,
    required this.sourceDuration,
    required this.start,
    required this.duration,
    required this.speed,
    required this.preservePitch,
    required this.pitchSemitones,
    required this.gain,
    required this.fadeIn,
    required this.fadeOut,
    required this.equalizer,
    required this.reversed,
    required this.voiceEffect,
  });

  final String assetId;
  final Duration sourceIn;
  final Duration sourceDuration;
  final Duration start;
  final Duration duration;
  final double speed;
  final bool preservePitch;
  final double pitchSemitones;
  final double gain;
  final Duration fadeIn;
  final Duration fadeOut;
  final EqualizerSettings? equalizer;
  final bool reversed;
  final VoiceEffect voiceEffect;
}
