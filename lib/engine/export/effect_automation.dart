/// Turns keyframed effect parameters into an FFmpeg `sendcmd` script.
///
/// ## The problem this solves
///
/// A filter's parameters are fixed when the graph is built. So an effect whose
/// blur radius ramps from 0 to 30 over two seconds would render at whatever
/// value it had at `t=0` — the preview animates, the export does not. That is
/// a WYSIWYG break, and the worst kind: invisible until after the render.
///
/// ## How it is fixed
///
/// FFmpeg's `sendcmd` filter can change parameters of *downstream* filters at
/// given times, provided the target filter advertises command support (the `C`
/// flag in `ffmpeg -filters`). Each animated filter instance is given a label
/// (`gblur@fx_abc`), and a script sets its parameters on a fixed sampling grid.
///
/// `sendcmd` does not interpolate — each command is a step. Sampling at
/// [_samplesPerSecond] is well above the point where stepping is perceptible
/// for the parameters involved, and keeps the script small.
///
/// The script is emitted as a **file** rather than inline commands: the inline
/// form has to survive three levels of FFmpeg quoting (`;` and spaces are both
/// separators), and a file sidesteps that entirely.
///
/// This class performs **no I/O** — it returns the script text, and
/// [ExportEngine] writes it. That keeps [TimelineCompiler] pure and testable.
library;

import '../../core/utils/time_utils.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/effect.dart';
import '../../domain/entities/keyframe.dart';
import '../effects/effect_catalog.dart';
import '../ffmpeg/filter_graph.dart';

/// A `sendcmd` script the export engine must write before running the graph.
class CommandScript {
  const CommandScript({required this.path, required this.contents});

  final String path;
  final String contents;

  int get commandCount =>
      contents.split('\n').where((l) => l.trim().isNotEmpty).length;
}

/// The result of preparing one clip's effect automation.
class EffectAutomation {
  const EffectAutomation({
    required this.script,
    required this.staticEffectTypes,
  });

  /// Null when nothing on this clip is animated.
  final CommandScript? script;

  /// Effects that *are* animated but whose FFmpeg filter cannot accept runtime
  /// commands, so they render at their first-frame value. Surfaced as an
  /// export warning rather than silently dropped.
  final List<EffectType> staticEffectTypes;

  bool get hasScript => script != null;
}

abstract final class EffectAutomationCompiler {
  /// Commands per second of clip time. 10 Hz is smooth for blur radius,
  /// brightness and colour parameters, and gives a 10-second clip 100 lines
  /// per animated parameter rather than 300 at frame rate.
  static const int _samplesPerSecond = 10;

  /// Labels the filter instances an animated effect targets, so `sendcmd` can
  /// address them. Mutates the [filters] list in place — it is freshly built
  /// per clip by [EffectCatalog.buildChain].
  ///
  /// Returns the label assigned per effect, keyed by effect id.
  static String labelFor(Effect effect) =>
      'fx${effect.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}';

  /// Label for the filter instance that carries a clip's animated opacity.
  static String opacityLabelFor(Clip clip) =>
      'op${clip.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}';

  /// Label for the one carrying its animated rotation.
  static String rotationLabelFor(Clip clip) =>
      'rot${clip.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}';

  /// Applies instance labels to every filter an animated effect owns.
  static void applyLabels(
    List<Filter> filters,
    List<Effect> effects,
  ) {
    for (final effect in effects) {
      if (!effect.isAnimated) continue;
      final spec = EffectCatalog.specFor(effect.type);
      if (spec == null || !spec.supportsExportAnimation) continue;

      final label = labelFor(effect);
      final targets = spec.commandTargets;

      for (final filter in filters) {
        // Only label an instance once. Callers pass one effect's own filters,
        // which matters: an adjust and a grade both emit `colorbalance`, and
        // labelling across a merged list would hand the grade's commands to
        // the adjust's instance — the grade would then never animate and the
        // adjust would animate to values meant for something else.
        if (targets.contains(filter.name) && filter.instanceLabel == null) {
          filter.labelled(label);
        }
      }
    }
  }

  /// Picks the instant an animated effect should be *built* at.
  ///
  /// The base filter chain is constructed once, and `sendcmd` then drives it.
  /// Building at `t=0` breaks for an effect that ramps up *from* zero: at zero
  /// the emitter returns no filters at all (they correctly no-op), so there is
  /// no instance left in the graph for the commands to address, and the effect
  /// silently never appears.
  ///
  /// Resolving at the animation's peak guarantees the instance exists. Its
  /// initial parameter values are immediately overwritten by the `t=0` command,
  /// so the peak value is never actually seen.
  static ResolvedEffect representativeResolution(
    Effect effect,
    Duration duration,
  ) {
    if (!effect.isAnimated || duration <= Duration.zero) {
      return effect.resolveAt(Duration.zero);
    }

    const probes = 12;
    var best = effect.resolveAt(Duration.zero);
    var bestMagnitude = _magnitude(best);

    for (var i = 1; i <= probes; i++) {
      final at = Duration(microseconds: duration.inMicroseconds * i ~/ probes);
      final candidate = effect.resolveAt(at);
      final magnitude = _magnitude(candidate);
      if (magnitude > bestMagnitude) {
        bestMagnitude = magnitude;
        best = candidate;
      }
    }
    return best;
  }

  static double _magnitude(ResolvedEffect effect) {
    var total = effect.intensity;
    for (final value in effect.values.values) {
      total += value.abs();
    }
    return total;
  }

  /// Builds the automation for one clip.
  ///
  /// [scriptPath] is where the engine will write it; this function only names
  /// it. Times in the script are clip-local, which is correct because every
  /// segment is rebased with `setpts=PTS-STARTPTS` before effects run.
  static EffectAutomation compile({
    required Clip clip,
    required String scriptPath,
    required int fps,
  }) {
    final animated = clip.activeEffects.where((e) => e.isAnimated).toList();
    final transform = clip.transform;
    final hasTransformAnimation =
        transform.opacity.isAnimated || transform.rotation.isAnimated;
    if (animated.isEmpty && !hasTransformAnimation) {
      return const EffectAutomation(script: null, staticEffectTypes: []);
    }

    final unsupported = <EffectType>[];
    final lines = <String>[];

    // Opacity and rotation are transform channels, not effects, but they are
    // driven the same way: both `colorchannelmixer` and `rotate` accept
    // runtime commands, so the machinery built for animated effects covers
    // them with no new mechanism.
    if (transform.opacity.isAnimated) {
      lines.addAll(
        _channelScript(
          channel: transform.opacity,
          target: 'colorchannelmixer@${opacityLabelFor(clip)}',
          parameter: 'aa',
          duration: clip.duration,
          fps: fps,
          clampLow: 0,
          clampHigh: 1,
        ),
      );
    }
    if (transform.rotation.isAnimated) {
      lines.addAll(
        _channelScript(
          channel: transform.rotation,
          target: 'rotate@${rotationLabelFor(clip)}',
          parameter: 'angle',
          duration: clip.duration,
          fps: fps,
          // `rotate` speaks radians; the entity stores degrees because that
          // is what the inspector shows.
          transformValue: (degrees) => degrees * 3.14159265358979 / 180,
        ),
      );
    }

    for (final effect in animated) {
      final spec = EffectCatalog.specFor(effect.type);
      if (spec == null) continue;
      if (!spec.supportsExportAnimation) {
        unsupported.add(effect.type);
        continue;
      }

      final label = labelFor(effect);
      lines.addAll(_scriptFor(effect, spec, label, clip.duration, fps));
    }

    if (lines.isEmpty) {
      return EffectAutomation(script: null, staticEffectTypes: unsupported);
    }

    return EffectAutomation(
      script: CommandScript(
        path: scriptPath,
        contents: '${lines.join('\n')}\n',
      ),
      staticEffectTypes: unsupported,
    );
  }

  /// The timestamp of the clip's final frame.
  ///
  /// A command scheduled at exactly the clip's duration is never executed —
  /// there is no frame at that instant — so an animation's endpoint value
  /// would never be applied. A fade to black stops one sample short of black,
  /// which is visible, and was.
  static Duration _lastFrameTime(Duration duration, int fps) {
    final frame = Duration(microseconds: (1e6 / (fps <= 0 ? 30 : fps)).round());
    final last = duration - frame;
    return last < Duration.zero ? Duration.zero : last;
  }

  static Duration _clampToLastFrame(Duration at, Duration lastFrame) =>
      at > lastFrame ? lastFrame : at;

  /// Sample lines for one animated transform channel.
  static List<String> _channelScript({
    required AnimatableDouble channel,
    required String target,
    required String parameter,
    required Duration duration,
    required int fps,
    double? clampLow,
    double? clampHigh,
    double Function(double)? transformValue,
  }) {
    if (duration <= Duration.zero) return const [];

    final sampleCount = (duration.inMicroseconds * _samplesPerSecond / 1e6)
        .ceil()
        .clamp(2, 6000);
    final step = Duration(microseconds: duration.inMicroseconds ~/ sampleCount);
    final lastFrame = _lastFrameTime(duration, fps);

    final lines = <String>[];
    double? previous;

    for (var i = 0; i <= sampleCount; i++) {
      final at = _clampToLastFrame(step * i, lastFrame);
      if (step * i > duration) break;

      var value = channel.valueAt(at);
      if (clampLow != null || clampHigh != null) {
        value = value.clamp(clampLow ?? value, clampHigh ?? value);
      }
      value = transformValue?.call(value) ?? value;

      // A channel that barely moves between samples costs one line, not a
      // hundred — the same economy the effect path uses.
      if (previous != null && (value - previous).abs() < 1e-4) continue;
      previous = value;

      lines.add(
        '${TimeUtils.toFfmpegSeconds(at)} $target $parameter '
        '${FilterGraph.formatDouble(value)};',
      );
    }
    return lines;
  }

  static List<String> _scriptFor(
    Effect effect,
    EffectSpec spec,
    String label,
    Duration duration,
    int fps,
  ) {
    final sampleCount =
        (duration.inMicroseconds * _samplesPerSecond / 1e6).ceil().clamp(2, 6000);
    final step = Duration(
      microseconds: duration.inMicroseconds ~/ sampleCount,
    );

    final lines = <String>[];
    final lastFrame = _lastFrameTime(duration, fps);

    for (final binding in spec.commands) {
      double? previous;

      for (var i = 0; i <= sampleCount; i++) {
        if (step * i > duration) break;
        final at = _clampToLastFrame(step * i, lastFrame);

        final resolved = effect.resolveAt(at);
        final value = binding.valueAt(resolved);

        // Skip samples that would not change anything. A parameter that is
        // constant while a sibling animates costs one line, not hundreds.
        if (previous != null && (value - previous).abs() < 1e-4) continue;
        previous = value;

        // Target syntax is `filter@label`, matching how the instance is
        // emitted into the graph by `Filter.qualifiedName`.
        lines.add(
          '${TimeUtils.toFfmpegSeconds(at)} '
          '${binding.filter}@$label ${binding.parameter} '
          '${FilterGraph.formatDouble(value)};',
        );
      }
    }

    for (final binding in spec.stringCommands) {
      String? previous;

      for (var i = 0; i <= sampleCount; i++) {
        if (step * i > duration) break;
        final at = _clampToLastFrame(step * i, lastFrame);

        final value = binding.valueAt(effect.resolveAt(at));
        if (value == null || value == previous) continue;
        previous = value;

        // Quoted here rather than by the graph escaper: this is a `sendcmd`
        // script, not a filter description, and its parser wants the argument
        // wrapped as one token when it contains spaces — which a curve, being
        // a list of points, always does.
        lines.add(
          '${TimeUtils.toFfmpegSeconds(at)} '
          '${binding.filter}@$label ${binding.parameter} '
          "'$value';",
        );
      }
    }

    return lines;
  }
}
