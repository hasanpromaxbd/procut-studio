/// The compiled description of a render, produced by [TimelineCompiler] and
/// executed by [ExportEngine].
///
/// Separating "work out what to run" from "run it" is what makes the export
/// path testable: the compiler is pure, so a unit test can assert on the
/// generated command without FFmpeg, a device, or a media file.
library;

import 'package:flutter/foundation.dart';

import 'effect_automation.dart';

/// A file fed to FFmpeg with `-i`, plus the input-specific flags that must
/// precede it (`-loop`, `-framerate`, `-ss`).
@immutable
class RenderInput {
  const RenderInput({
    required this.path,
    this.leadingArgs = const [],
    this.label,
  });

  final String path;
  final List<String> leadingArgs;

  /// Human-readable note for logs, e.g. `text:clip_123`.
  final String? label;

  List<String> toArgs() => [...leadingArgs, '-i', path];
}

/// An FFmpeg invocation that must complete before the main pass.
///
/// Used for the operations a single filter graph cannot express: reversing a
/// clip (needs the whole clip buffered), and rasterising text/sticker layers
/// through Flutter's own painter so preview and export agree pixel-for-pixel.
@immutable
class PreRenderStep {
  const PreRenderStep({
    required this.id,
    required this.description,
    required this.command,
    required this.outputPath,
    this.estimatedDuration = Duration.zero,
    this.weight = 1.0,
  });

  final String id;
  final String description;
  final String command;
  final String outputPath;
  final Duration estimatedDuration;

  /// Relative cost, used to weight the progress bar so a 10-second reverse
  /// does not occupy the same share as a 2-minute encode.
  final double weight;
}

/// Work that has to run on the Dart side (rasterising layers) rather than in
/// FFmpeg. Executed before [PreRenderStep]s that consume its output.
@immutable
class RasterStep {
  const RasterStep({
    required this.id,
    required this.clipId,
    required this.outputPath,
    required this.isSequence,
    required this.frameCount,
    required this.description,
  });

  final String id;
  final String clipId;

  /// A single PNG, or a directory holding `%05d.png` when [isSequence].
  final String outputPath;

  /// True when the layer animates and needs one PNG per frame.
  final bool isSequence;

  final int frameCount;
  final String description;
}

@immutable
class RenderPlan {
  const RenderPlan({
    required this.inputs,
    required this.filterGraph,
    required this.outputArgs,
    required this.outputPath,
    required this.duration,
    required this.width,
    required this.height,
    required this.fps,
    this.rasterSteps = const [],
    this.preRenderSteps = const [],
    this.commandScripts = const [],
    this.videoOutLabel,
    this.audioOutLabel,
    this.warnings = const [],
  });

  final List<RenderInput> inputs;

  /// The `-filter_complex` string. Empty when the render is a straight remux.
  final String filterGraph;

  /// Encoder/muxer flags appended after the maps.
  final List<String> outputArgs;

  final String outputPath;
  final Duration duration;
  final int width;
  final int height;
  final int fps;

  final List<RasterStep> rasterSteps;
  final List<PreRenderStep> preRenderSteps;

  /// `sendcmd` scripts driving keyframed effect parameters. The engine writes
  /// these to disk before the main pass; the compiler only names them, so it
  /// stays free of I/O and therefore testable.
  final List<CommandScript> commandScripts;

  /// Pad carrying the finished picture. Null when the timeline has no video.
  final String? videoOutLabel;

  /// Pad carrying the finished mix. Null when the timeline is silent.
  final String? audioOutLabel;

  /// Non-fatal issues worth telling the user about before they wait.
  final List<String> warnings;

  bool get hasVideo => videoOutLabel != null;
  bool get hasAudio => audioOutLabel != null;

  /// Total pre-render weight, for progress apportioning.
  double get preRenderWeight =>
      preRenderSteps.fold(0.0, (sum, step) => sum + step.weight);

  /// Assembles the full command line for the main pass.
  String buildCommand() {
    final args = <String>['-y', '-hide_banner'];

    for (final input in inputs) {
      args.addAll(input.toArgs());
    }

    if (filterGraph.isNotEmpty) {
      args.addAll(['-filter_complex', quoteArg(filterGraph)]);
    }

    if (videoOutLabel != null) {
      args.addAll(['-map', '[$videoOutLabel]']);
    }
    if (audioOutLabel != null) {
      args.addAll(['-map', '[$audioOutLabel]']);
    }

    args.addAll(outputArgs);
    args.add(quoteArg(outputPath));
    return args.join(' ');
  }

  /// FFmpegKit parses the command with shell-like quoting rules, so any
  /// argument containing whitespace or a quote must be wrapped.
  static String quoteArg(String value) {
    if (!value.contains(RegExp(r'''[\s"']'''))) return value;
    return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  @override
  String toString() =>
      'RenderPlan(${inputs.length} inputs, ${width}x$height@$fps, '
      '${duration.inMilliseconds}ms, ${preRenderSteps.length} pre-steps)';
}
