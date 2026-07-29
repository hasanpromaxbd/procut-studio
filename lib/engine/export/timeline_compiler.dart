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
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/text_style_spec.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/transform2d.dart';
import '../../domain/entities/transition.dart';
import '../effects/effect_catalog.dart';
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
        final index = registerInput(
          'file:$sourcePath',
          RenderInput(path: sourcePath, label: 'media:$sourcePath'),
        );

        final chain = graph.chain(inputs: ['$index:v'], outputs: [label]);

        if (clip.isFrozen) {
          chain.thenAll(
            Filters.freezeFrame(clip.freezeFrameAt!, clip.duration, fps),
          );
        } else {
          chain
              .then(Filters.trim(sourceIn, sourceIn + clip.sourceDuration))
              .then(Filters.resetPts());
          if (clip.isSpeedAltered) {
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
        _appendGeometry(chain, clip.transform, asset, outWidth, outHeight);
        _collectAutomation(
          _appendEffects(chain, clip, workspaceDir),
          commandScripts,
          warnings,
        );
        chain.then(Filter('format', {'pix_fmts': 'yuva420p'}));
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

      case AudioClip():
        return null; // handled by the audio pass
    }
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
    final stemLabels = <String>[];

    for (final track in timeline.tracks) {
      if (!timeline.isTrackAudible(track)) continue;

      for (final clip in track.clips) {
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

        if (source.pitchSemitones.abs() > 0.01) {
          chain.thenAll(
            Filters.pitchShift(
              source.pitchSemitones,
              sampleRate: settings.audioSampleRate,
            ),
          );
        }

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

        stemLabels.add(label);
      }
    }

    if (stemLabels.isEmpty) return null;

    final mixed = graph.newLabel('aout');
    if (stemLabels.length == 1) {
      graph
          .chain(inputs: stemLabels, outputs: [mixed])
          .then(Filters.atrim(Duration.zero, timelineDuration))
          .then(Filters.resetAudioPts());
    } else {
      graph
          .chain(inputs: stemLabels, outputs: [mixed])
          .then(Filters.mixAudio(stemLabels.length))
          .then(Filters.atrim(Duration.zero, timelineDuration))
          .then(Filters.resetAudioPts());

      if (stemLabels.length > 8) {
        warnings.add(
          'This project mixes ${stemLabels.length} audio sources; '
          'the export will take longer than usual.',
        );
      }
    }
    return mixed;
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
}
