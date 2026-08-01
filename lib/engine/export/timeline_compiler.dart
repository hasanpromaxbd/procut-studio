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

import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../core/logging/app_logger.dart';
import '../../core/utils/math_utils.dart';
import '../../core/utils/time_utils.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/effect.dart';
import '../../domain/entities/export_range.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/keyframe.dart';
import '../../domain/entities/layer_frame.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/text_style_spec.dart';
import '../../domain/entities/timeline.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/transform2d.dart';
import '../../domain/entities/transition.dart';
import '../../domain/entities/voice_effect.dart';
import '../effects/effect_catalog.dart';
import '../effects/frame_compiler.dart';
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
    ExportRange? range,
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
    // A track composites with the blend mode of the clips on it. Per-track
    // rather than per-clip because compositing happens after each track has
    // been assembled into one stream — and a track whose clips disagree about
    // blending is not a thing an editor can express anyway.
    final trackBlendModes = <LayerBlendMode>[];
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
      if (label != null) {
        trackLabels.add(label);
        trackBlendModes.add(_blendModeOf(track));
      }
    }

    // ── 3. Composite ─────────────────────────────────────────────────
    var currentVideo = baseLabel;
    for (final (index, trackLabel) in trackLabels.indexed) {
      final mode = trackBlendModes[index];
      currentVideo = mode == LayerBlendMode.normal
          ? _overlayTrack(graph, currentVideo, trackLabel)
          : _blendTrack(graph, currentVideo, trackLabel, mode);
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

    // Branding goes on last, over everything including adjustment layers —
    // a watermark under a grade is a watermark that changes colour.
    final mark = settings.watermark;
    if (mark.isActive) {
      final index = registerInput(
        'watermark:${mark.imagePath}',
        RenderInput(
          path: mark.imagePath,
          // `-loop 1` alone is an *infinite* stream. Bounding it with `-t` is
          // what stops the render running forever; `shortest=1` below is the
          // belt to this pair of braces.
          leadingArgs: [
            '-loop', '1',
            '-t', TimeUtils.toFfmpegSeconds(duration),
          ],
          label: 'watermark',
        ),
      );

      final scaled = graph.newLabel('wm');
      graph
          .chain(inputs: ['$index:v'], outputs: [scaled])
          .then(
            Filter('scale', {
              'w': (outWidth * mark.scale.clamp(0.02, 1.0)).round(),
              // -1 keeps the logo's aspect ratio; a squashed logo is worse
              // than no logo.
              'h': -1,
              'flags': 'bicubic',
            }),
          )
          .then(Filter('format', {'pix_fmts': 'rgba'}))
          .then(
            Filter('colorchannelmixer', {
              'aa': FilterGraph.formatDouble(mark.opacity.clamp(0.0, 1.0)),
            }),
          );

      final (wx, wy) = mark.overlayPosition(outWidth);
      final branded = graph.newLabel('comp');
      graph
          .chain(inputs: [currentVideo, scaled], outputs: [branded])
          .then(
            // `shortest=1` is not optional here. The watermark is a looped
            // still; with the default (0) the overlay runs until the *longest*
            // input ends, and a looped image never does — the render simply
            // hangs. Verified the hard way.
            Filter('overlay', {
              'x': wx,
              'y': wy,
              'format': 'auto',
              'shortest': 1,
            }),
          );
      currentVideo = branded;
    }

    // A range trims the *tail* of the graph rather than the timeline, so
    // every clip's placement, speed and automation is computed exactly as it
    // would be for a full render — a range export must be a window onto the
    // real thing, not a different edit that happens to be shorter.
    final window = range?.clampedTo(duration);

    // Final format conversion. yuv420p is the only chroma layout every Android
    // decoder and every social platform reliably accepts.
    final videoOut = graph.newLabel('vout');
    final videoTail = graph
        .chain(inputs: [currentVideo], outputs: [videoOut])
        .then(Filters.fps(fps));
    if (window != null) {
      videoTail
          .then(Filters.trim(window.start, window.end))
          .then(Filters.resetPts());
    }
    videoTail
        .then(Filter('format', {'pix_fmts': 'yuv420p'}))
        .then(Filters.setSar('1'));

    // ── 4. Audio ─────────────────────────────────────────────────────
    // GIF has no audio stream; compiling one would leave its labels dangling
    // and FFmpeg refuses a graph with an unconnected output.
    final fullAudio = settings.container == ExportContainer.gif
        ? null
        : _compileAudio(
      graph: graph,
      project: project,
      settings: settings,
      timelineDuration: duration,
      registerInput: registerInput,
      warnings: warnings,
    );

    // The mix is trimmed to the same window, so picture and sound stay in
    // step — trimming only one is the classic way to ship a drifting export.
    String? audioOut = fullAudio;
    if (fullAudio != null && window != null) {
      final trimmed = graph.newLabel('arange');
      graph
          .chain(inputs: [fullAudio], outputs: [trimmed])
          .then(Filters.atrim(window.start, window.end))
          .then(Filters.resetAudioPts());
      audioOut = trimmed;
    }

    // ── 5. Output flags ──────────────────────────────────────────────
    if (settings.container == ExportContainer.gif) {
      // GIF is its own world: 256 colours via a two-stage palette *inside*
      // one graph (split → palettegen → paletteuse), no audio, gif muxer.
      final paletted = graph.newLabel('gif');
      final split1 = graph.newLabel('gs');
      final split2 = graph.newLabel('gp');
      final palette = graph.newLabel('pal');
      graph.chain(inputs: [videoOut], outputs: [split1, split2])
          .then(Filter('split')..arg('2'));
      graph.chain(inputs: [split1], outputs: [palette])
          .then(Filter('palettegen', {'stats_mode': 'diff'}));
      graph.chain(inputs: [split2, palette], outputs: [paletted]).then(
        Filter('paletteuse', {'dither': 'bayer', 'bayer_scale': 4}),
      );

      final gifArgs = <String>['-r', '$fps', '-f', 'gif', '-an'];
      final missingGif = graph.validate();
      if (missingGif.isNotEmpty) {
        _log.e('graph references undefined labels', fields: {'labels': missingGif});
        warnings.add('Internal graph error: unresolved ${missingGif.join(', ')}.');
      }
      final plan = RenderPlan(
        inputs: inputs,
        filterGraph: graph.build(),
        outputArgs: gifArgs,
        outputPath: outputPath,
        duration: duration,
        width: outWidth,
        height: outHeight,
        fps: fps,
        rasterSteps: rasterSteps,
        preRenderSteps: preRenderSteps,
        commandScripts: commandScripts,
        videoOutLabel: paletted,
        audioOutLabel: null,
        warnings: warnings,
      );
      _log.i('compiled', fields: {'plan': plan.toString()});
      return plan;
    }

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
      duration: window?.duration ?? duration,
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

        // A ramp is built from its own sub-chains and arrives already
        // re-timed; everything else starts from one chain off the input.
        final FilterChain chain;
        if (!clip.isFrozen && clip.hasSpeedRamp) {
          final ramped = _rampedVideo(
            graph: graph,
            clip: clip,
            inputPad: '$index:v',
            sourceIn: effectiveIn,
            warnings: warnings,
          );
          chain = graph.chain(inputs: [ramped], outputs: [label]);
        } else {
          chain = graph.chain(inputs: ['$index:v'], outputs: [label]);

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
            if (clip.isSpeedAltered) {
              chain.then(Filters.videoSpeed(clip.speed));
            }
          }
        }

        chain.then(Filters.fps(fps));
        final automation = _beginAutomation(chain, clip, workspaceDir, fps);
        // Same decision as for stills: an animated transform on video is a
        // digital pan/zoom and has to render, not freeze at frame one.
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
          _appendGeometry(
            chain,
            clip.transform,
            asset,
            outWidth,
            outHeight,
            frame: clip.frame,
            clipForLabels: clip,
          );
        }
        _appendEffects(chain, clip, automation);
        _collectAutomation(automation, commandScripts, warnings);
        chain.then(Filter('format', {'pix_fmts': 'yuva420p'}));
        chain.thenAll(MaskCompiler.buildAnimated(clip.mask, clip.duration));
        _appendOpacity(chain, clip);

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
        final automation = _beginAutomation(chain, clip, workspaceDir, fps);

        // Animated scale/position is a camera move (Ken Burns on a still,
        // a digital push on video). `zoompan` is the filter built for it;
        // the static geometry path reads `.staticValue` and would freeze it.
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
          _appendGeometry(
            chain,
            clip.transform,
            asset,
            outWidth,
            outHeight,
            frame: clip.frame,
            clipForLabels: clip,
          );
        }
        _appendEffects(chain, clip, automation);
        _collectAutomation(automation, commandScripts, warnings);
        chain.then(Filter('format', {'pix_fmts': 'yuva420p'}));
        chain.thenAll(MaskCompiler.buildAnimated(clip.mask, clip.duration));
        _appendOpacity(chain, clip);

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
                  clip.transform.isAnimated ||
                  // The word highlight changes every frame by definition.
                  clip.isKaraoke)
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
        final automation = _beginAutomation(chain, clip, workspaceDir, fps);
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
        _appendEffects(chain, clip, automation);
        _collectAutomation(automation, commandScripts, warnings);
        final maskFilters = MaskCompiler.build(
          clip.mask.resolveAt(Duration.zero),
        );
        chain.thenAll(maskFilters);
        _appendOpacity(chain, clip);
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
  /// How many constant-rate pieces a ramp is cut into.
  ///
  /// `setpts` takes one multiplier for a whole stream, so an arbitrary eased
  /// curve cannot be expressed directly — it has to be approximated by
  /// pieces. Sixteen is where the stepping stops being visible on the ramps
  /// people actually build; more pieces cost graph size and encoder
  /// start-ups, not smoothness.
  static const int _rampSegments = 16;

  /// The source window and playback rate of each piece of a ramp.
  ///
  /// Split by *timeline* time and converted to source time through
  /// `integrateSpeed`, so the pieces butt together exactly and the clip still
  /// consumes precisely the source it says it does. Splitting by source time
  /// instead would drift against the clip's own duration maths.
  static List<({Duration sourceStart, Duration sourceEnd, double rate})>
  rampSegments(MediaClip clip, Duration sourceIn) {
    final segments =
        <({Duration sourceStart, Duration sourceEnd, double rate})>[];
    final total = clip.duration;
    if (total <= Duration.zero) return segments;

    for (var i = 0; i < _rampSegments; i++) {
      final from = Duration(
        microseconds: total.inMicroseconds * i ~/ _rampSegments,
      );
      final to = Duration(
        microseconds: total.inMicroseconds * (i + 1) ~/ _rampSegments,
      );
      final span = to - from;
      if (span <= Duration.zero) continue;

      final consumedBefore = clip.integrateSpeed(Duration.zero, from);
      final consumed = clip.integrateSpeed(from, to);
      if (consumed <= Duration.zero) continue;

      segments.add((
        sourceStart: sourceIn + consumedBefore,
        sourceEnd: sourceIn + consumedBefore + consumed,
        // The average rate over this piece: source consumed per second of
        // timeline.
        rate: consumed.inMicroseconds / span.inMicroseconds,
      ));
    }
    return segments;
  }

  /// Builds the video side of a ramp and returns its output label.
  String _rampedVideo({
    required FilterGraph graph,
    required VideoClip clip,
    required String inputPad,
    required Duration sourceIn,
    required List<String> warnings,
  }) {
    final segments = rampSegments(clip, sourceIn);
    if (segments.isEmpty) {
      final passthrough = graph.newLabel('ramp');
      graph
          .chain(inputs: [inputPad], outputs: [passthrough])
          .then(Filters.trim(sourceIn, sourceIn + clip.sourceDuration))
          .then(Filters.resetPts());
      return passthrough;
    }

    // One `split` feeding every piece: the source is decoded once and each
    // piece trims its own window out of it.
    final branches = [
      for (var i = 0; i < segments.length; i++) graph.newLabel('rin'),
    ];
    graph
        .chain(inputs: [inputPad], outputs: branches)
        .then(Filter('split')..arg('${branches.length}'));

    final pieces = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final piece = graph.newLabel('rseg');
      graph
          .chain(inputs: [branches[i]], outputs: [piece])
          .then(Filters.trim(segment.sourceStart, segment.sourceEnd))
          .then(Filters.resetPts())
          .then(Filters.videoSpeed(segment.rate));
      pieces.add(piece);
    }

    final joined = graph.newLabel('ramp');
    graph
        .chain(inputs: pieces, outputs: [joined])
        .then(Filter('concat', {'n': pieces.length, 'v': 1, 'a': 0}))
        .then(Filters.resetPts());

    warnings.add(
      'A speed ramp is rendered as ${pieces.length} constant-rate segments; '
      'a very long ramp may show slight stepping.',
    );
    return joined;
  }

  /// Builds the audio side of a ramp and returns its output label.
  ///
  /// Same segmentation as the picture, from the same [rampSegments], so the
  /// two cannot drift apart: every piece covers the same source window and is
  /// stretched by the same factor.
  String _rampedAudio({
    required FilterGraph graph,
    required MediaClip clip,
    required String inputPad,
    required Duration sourceIn,
  }) {
    final segments = rampSegments(clip, sourceIn);
    if (segments.isEmpty) {
      final passthrough = graph.newLabel('aramp');
      graph
          .chain(inputs: [inputPad], outputs: [passthrough])
          .then(Filters.atrim(sourceIn, sourceIn + clip.sourceDuration))
          .then(Filters.resetAudioPts());
      return passthrough;
    }

    final branches = [
      for (var i = 0; i < segments.length; i++) graph.newLabel('arin'),
    ];
    graph
        .chain(inputs: [inputPad], outputs: branches)
        .then(Filter('asplit')..arg('${branches.length}'));

    final pieces = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final piece = graph.newLabel('arseg');
      graph
          .chain(inputs: [branches[i]], outputs: [piece])
          .then(Filters.atrim(segment.sourceStart, segment.sourceEnd))
          .then(Filters.resetAudioPts())
          // `atempo` caps at 2× per instance, so a steep ramp cascades —
          // `audioSpeed` already handles that decomposition.
          .thenAll(Filters.audioSpeed(segment.rate));
      pieces.add(piece);
    }

    final joined = graph.newLabel('aramp');
    graph
        .chain(inputs: pieces, outputs: [joined])
        .then(Filter('concat', {'n': pieces.length, 'v': 0, 'a': 1}))
        .then(Filters.resetAudioPts());
    return joined;
  }

  /// The blend mode a track composites with: the first its clips agree on.
  static LayerBlendMode _blendModeOf(Track track) {
    for (final clip in track.clips) {
      if (clip.enabled && clip.transform.blendMode != LayerBlendMode.normal) {
        return clip.transform.blendMode;
      }
    }
    return LayerBlendMode.normal;
  }

  String _overlayTrack(FilterGraph graph, String base, String layer) {
    final next = graph.newLabel('comp');
    graph
        .chain(inputs: [base, layer], outputs: [next])
        .then(Filters.overlay(x: '0', y: '0', format: 'auto'));
    return next;
  }

  /// Composites [layer] onto [base] with a blend mode, honouring alpha.
  ///
  /// `blend` combines two whole frames and ignores alpha entirely, so used on
  /// its own it blends the transparent surround as well — every pixel the
  /// layer does not cover gets mixed with black. Whether that is visible
  /// depends on the mode (`screen` with black is a no-op; `multiply` blacks
  /// the frame out), which is exactly the kind of bug that ships.
  ///
  /// So: blend the frames, reattach the layer's own alpha to the result, and
  /// overlay that. Only the pixels the layer actually covers are affected.
  String _blendTrack(
    FilterGraph graph,
    String base,
    String layer,
    LayerBlendMode mode,
  ) {
    final baseForBlend = graph.newLabel('bb');
    final baseForOver = graph.newLabel('bo');
    graph
        .chain(inputs: [base], outputs: [baseForBlend, baseForOver])
        .then(Filter('split')..arg('2'));

    final layerRgb = graph.newLabel('lb');
    final layerAlpha = graph.newLabel('la');
    graph
        .chain(inputs: [layer], outputs: [layerRgb, layerAlpha])
        .then(Filter('split')..arg('2'));

    final mask = graph.newLabel('lmask');
    graph
        .chain(inputs: [layerAlpha], outputs: [mask])
        .then(Filter('alphaextract'));

    final blended = graph.newLabel('bl');
    graph
        .chain(inputs: [baseForBlend, layerRgb], outputs: [blended])
        .then(Filters.blend(mode.id));

    final masked = graph.newLabel('blm');
    graph
        .chain(inputs: [blended, mask], outputs: [masked])
        .then(Filter('alphamerge'));

    return _overlayTrack(graph, baseForOver, masked);
  }

  /// Renders an animated transform through `zoompan`.
  ///
  /// Applies to video as well as stills: `zoompan` at `d=1` emits one frame
  /// per input frame, so a clip keeps its length and its motion. The obvious
  /// alternative — time expressions in `crop` — is not safe to build on:
  /// FFmpeg documents crop's `w`/`h` as evaluated once at configuration, and
  /// although some builds animate them anyway, FFmpegKit's need not.
  void _appendCameraMove(
    FilterChain chain,
    Clip clip, {
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
        'A camera move has more than two keyframes; the export plays it as '
        'one move between the first and last.',
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
      ..thenAll(
        Filters.scaleToFit(
          outWidth * 2,
          outHeight * 2,
          background: 0x00000000,
        ),
      )
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

  /// Crop → flip → rotate → **place**. Order matters: cropping after a
  /// rotation would cut the wrong region.
  ///
  /// "Place" is the part that used to be missing. The old path fitted every
  /// layer to the canvas, centred, and threw the transform's position and
  /// scale away — so a PiP the user had dragged into a corner snapped back to
  /// the middle on export, and a scaled one came out unscaled because the fit
  /// simply undid the scale. The layer is now scaled to its real size and
  /// padded at its real offset, which is what the preview does.
  ///
  /// Every layer keeps the canvas as its frame size, because the track-level
  /// `concat`/`xfade` requires all its segments to match. Position therefore
  /// lives in the pad offset rather than in the overlay step.
  void _appendGeometry(
    FilterChain chain,
    Transform2D transform,
    MediaAsset asset,
    int outWidth,
    int outHeight, {
    LayerFrame frame = LayerFrame.none,
    required Clip clipForLabels,
  }) {
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

    if (transform.rotation.isAnimated) {
      // Always emitted and labelled, for the same reason animated opacity is:
      // `sendcmd` needs an instance to talk to. `fillcolor=none` keeps the
      // corners transparent as the frame turns, rather than stamping black
      // over whatever is beneath.
      chain.then(
        Filter('rotate', {
          'angle': FilterGraph.formatDouble(
            transform.rotation.valueAt(Duration.zero) * 3.14159265358979 / 180,
          ),
          'fillcolor': 'none',
        })..labelled(EffectAutomationCompiler.rotationLabelFor(clipForLabels)),
      );
    } else {
      final rotation = transform.rotation.staticValue % 360;
      if (rotation.abs() > 0.01) {
        if (rotation % 90 == 0) {
          chain.thenAll(Filters.rotateQuarter((rotation ~/ 90).toInt()));
        } else {
          chain.then(Filters.rotate(rotation));
        }
      }
    }

    chain.thenAll(
      _placement(
        transform: transform,
        asset: asset,
        outWidth: outWidth,
        outHeight: outHeight,
        frame: frame,
      ),
    );
  }

  /// Scale-and-place filters for one layer.
  ///
  /// Exposed for tests and reused by every clip kind, so "where does a layer
  /// land" has exactly one answer in the codebase.
  static List<Filter> _placement({
    required Transform2D transform,
    required MediaAsset asset,
    required int outWidth,
    required int outHeight,
    LayerFrame frame = LayerFrame.none,
  }) {
    // The fitted size is the baseline the user's scale multiplies: scale 1
    // means "as large as it goes without cropping", which is what the preview
    // shows and what every editor means by 100%.
    final sourceW = asset.displayWidth <= 0 ? outWidth : asset.displayWidth;
    final sourceH = asset.displayHeight <= 0 ? outHeight : asset.displayHeight;
    final fitScale = math.min(outWidth / sourceW, outHeight / sourceH);

    final layerW = _even(sourceW * fitScale * transform.scaleX.staticValue);
    final layerH = _even(sourceH * fitScale * transform.scaleY.staticValue);
    if (layerW <= 0 || layerH <= 0) {
      return _offCanvas(outWidth, outHeight);
    }

    // Centre, then move by the transform — the same arithmetic the preview's
    // Transform widget performs.
    final left =
        ((outWidth - layerW) / 2 + transform.x.staticValue * outWidth).round();
    final top =
        ((outHeight - layerH) / 2 + transform.y.staticValue * outHeight)
            .round();

    final filters = <Filter>[
      Filter('scale', {'w': layerW, 'h': layerH, 'flags': 'bicubic'}),
      // Rounded corners and the border are cut here, while the layer is still
      // at its own size — after padding they would follow the canvas edges.
      ...FrameCompiler.build(frame, layerW, layerH),
    ];

    // Anything hanging off an edge has to be cut away before padding: `pad`
    // can only grow a frame, never crop one, and a negative offset is an
    // error rather than a shift.
    final cropX = math.max(0, -left);
    final cropY = math.max(0, -top);
    final visibleLeft = math.max(0, left);
    final visibleTop = math.max(0, top);
    final cropW = math.min(layerW - cropX, outWidth - visibleLeft);
    final cropH = math.min(layerH - cropY, outHeight - visibleTop);

    if (cropW <= 0 || cropH <= 0) {
      // Entirely off-canvas. A transparent frame keeps the track's segment
      // count and timing intact instead of desynchronising the concat.
      return _offCanvas(outWidth, outHeight);
    }

    if (cropX != 0 || cropY != 0 || cropW != layerW || cropH != layerH) {
      filters.add(
        Filter('crop', {'w': cropW, 'h': cropH, 'x': cropX, 'y': cropY}),
      );
    }

    if (cropW != outWidth || cropH != outHeight ||
        visibleLeft != 0 || visibleTop != 0) {
      filters.add(
        Filter('pad', {
          'w': outWidth,
          'h': outHeight,
          'x': visibleLeft,
          'y': visibleTop,
          // Transparent, not black. An opaque surround on an upper track
          // would hide every layer beneath it — the frame is made opaque by
          // the base colour source at the bottom of the stack, not by the
          // layers.
          'color': FilterGraph.colorFrom(0x00000000),
        }),
      );
    }

    return filters;
  }

  static List<Filter> _offCanvas(int outWidth, int outHeight) => [
    Filter('scale', {'w': 2, 'h': 2, 'flags': 'neighbor'}),
    Filter('pad', {
      'w': outWidth,
      'h': outHeight,
      'x': 0,
      'y': 0,
      'color': FilterGraph.colorFrom(0x00000000),
    }),
    Filter('format', {'pix_fmts': 'yuva420p'}),
    Filter('colorchannelmixer', {'aa': 0}),
  ];

  /// H.264 needs even dimensions, and an odd intermediate makes chroma
  /// subsampling round unpredictably between filters.
  static int _even(double value) {
    final rounded = value.round();
    return rounded.isEven ? rounded : rounded + 1;
  }

  /// Appends the clip's effect filters, wiring up `sendcmd` automation when
  /// any of them are keyframed.
  void _appendEffects(
    FilterChain chain,
    Clip clip,
    EffectAutomation automation,
  ) {
    final effects = clip.activeEffects;
    if (effects.isEmpty) return;

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

    if (automation.hasScript) {
      EffectAutomationCompiler.applyLabels(filters, effects);
    }
    chain.thenAll(filters);
  }

  /// Compiles a clip's automation and puts `sendcmd` at the head of its chain.
  ///
  /// At the head, deliberately: `sendcmd` only reaches filters *downstream* of
  /// it, and the animated channels are spread across the whole chain —
  /// rotation sits in the geometry stage, effects in the middle, opacity at
  /// the end. Inserting it beside the effects reached the last two and
  /// silently missed the first.
  EffectAutomation _beginAutomation(
    FilterChain chain,
    Clip clip,
    String workspaceDir,
    int fps,
  ) {
    final automation = EffectAutomationCompiler.compile(
      clip: clip,
      scriptPath: p.join(workspaceDir, 'fx_${clip.id}.cmd'),
      fps: fps,
    );
    if (automation.hasScript) {
      chain.then(
        Filter('sendcmd', {
          'f': FilterGraph.escapePath(automation.script!.path),
        }),
      );
    }
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

  /// Appends the alpha scale a clip's opacity implies.
  ///
  /// An *animated* opacity always emits the filter, labelled, even when it
  /// starts fully opaque: `sendcmd` can only address an instance that exists,
  /// and eliding it because frame one is opaque is exactly how a fade-out
  /// silently never happens.
  void _appendOpacity(FilterChain chain, Clip clip) {
    final transform = clip.transform;
    if (transform.opacity.isAnimated) {
      chain.then(
        Filter('colorchannelmixer', {
          'aa': FilterGraph.formatDouble(
            transform.opacity.valueAt(Duration.zero).clamp(0.0, 1.0),
          ),
        })..labelled(EffectAutomationCompiler.opacityLabelFor(clip)),
      );
      return;
    }

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
            rampClip: clip.hasSpeedRamp ? clip : null,
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
            rampClip: clip.hasSpeedRamp ? clip : null,
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
        final FilterChain chain;

        if (source.hasRamp) {
          // Re-timed in pieces upstream; what arrives here is already at the
          // clip's timeline length, so the shared speed handling below must
          // not touch it again.
          final ramped = _rampedAudio(
            graph: graph,
            clip: source.rampClip!,
            inputPad: '$index:a',
            sourceIn: source.sourceIn,
          );
          chain = graph.chain(inputs: [ramped], outputs: [label]);
        } else {
          chain = graph.chain(inputs: ['$index:a'], outputs: [label]);
          chain
              .then(
                Filters.atrim(
                  source.sourceIn,
                  source.sourceIn + source.sourceDuration,
                ),
              )
              .then(Filters.resetAudioPts());
        }

        if (source.reversed && !source.hasRamp) {
          chain.then(Filters.reverseAudio());
        }

        if (!source.hasRamp && (source.speed - 1.0).abs() > 1e-6) {
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
        // Equal-power for every audio fade: at a crossfade joint the curves
        // must sum to unity, and on a lone fade the qsin curve simply sounds
        // less abrupt than linear. One curve, both cases right.
        if (source.fadeIn > Duration.zero) {
          chain.then(
            Filters.audioFadeIn(
              Duration.zero,
              source.fadeIn,
              equalPower: true,
            ),
          );
        }
        if (source.fadeOut > Duration.zero) {
          chain.then(
            Filters.audioFadeOut(
              source.duration - source.fadeOut,
              source.fadeOut,
              equalPower: true,
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
    this.rampClip,
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

  /// Set when this source's clip has a speed ramp, so the mix can be re-timed
  /// segment by segment exactly as the picture is. Picture accelerating while
  /// sound plays at one rate is a drift that grows across the clip.
  final MediaClip? rampClip;

  bool get hasRamp => rampClip?.hasSpeedRamp ?? false;
}
