/// A typed builder for FFmpeg `-filter_complex` graphs.
///
/// Building these by string concatenation is where video pipelines go to die:
/// one missing `[label]` and FFmpeg reports a parse error 300 characters deep.
/// This models the graph as chains of filters with explicit input/output pads,
/// validates the labels, and escapes values in one audited place.
library;

import 'dart:math' as math;

/// One filter invocation, e.g. `scale=w=1080:h=1920:flags=lanczos`.
class Filter {
  Filter(this.name, [Map<String, Object?>? params])
    : params = <String, Object?>{...?params};

  final String name;
  final Map<String, Object?> params;

  /// Positional arguments for the handful of filters that take them
  /// (`fps`, `atempo`, …).
  final List<String> positional = [];

  Filter arg(String value) {
    positional.add(value);
    return this;
  }

  Filter set(String key, Object? value) {
    if (value != null) params[key] = value;
    return this;
  }

  String build() {
    final parts = <String>[
      ...positional.map(FilterGraph.escapeValue),
      ...params.entries
          .where((e) => e.value != null)
          .map((e) => '${e.key}=${FilterGraph.escapeValue(e.value!)}'),
    ];
    return parts.isEmpty ? name : '$name=${parts.join(':')}';
  }

  @override
  String toString() => build();
}

/// A linear sequence of filters from a set of input pads to a set of output
/// pads: `[0:v][1:v]overlay=x=10[out]`.
class FilterChain {
  FilterChain({
    List<String>? inputs,
    List<Filter>? filters,
    List<String>? outputs,
  }) : inputs = inputs ?? [],
       filters = filters ?? [],
       outputs = outputs ?? [];

  final List<String> inputs;
  final List<Filter> filters;
  final List<String> outputs;

  FilterChain then(Filter filter) {
    filters.add(filter);
    return this;
  }

  FilterChain thenAll(Iterable<Filter> more) {
    filters.addAll(more);
    return this;
  }

  FilterChain to(String label) {
    outputs.add(label);
    return this;
  }

  bool get isEmpty => filters.isEmpty;

  String build() {
    final buffer = StringBuffer();
    for (final input in inputs) {
      buffer.write('[$input]');
    }
    buffer.write(filters.map((f) => f.build()).join(','));
    for (final output in outputs) {
      buffer.write('[$output]');
    }
    return buffer.toString();
  }

  @override
  String toString() => build();
}

class FilterGraph {
  FilterGraph();

  final List<FilterChain> _chains = [];
  int _labelCounter = 0;

  bool get isEmpty => _chains.every((c) => c.isEmpty && c.outputs.isEmpty);

  /// Unique pad label. Prefixed so a graph is readable when it is dumped into
  /// the log after a failure.
  String newLabel([String prefix = 'l']) => '$prefix${_labelCounter++}';

  FilterChain chain({List<String>? inputs, List<String>? outputs}) {
    final chain = FilterChain(inputs: inputs, outputs: outputs);
    _chains.add(chain);
    return chain;
  }

  void add(FilterChain chain) => _chains.add(chain);

  /// Appends a raw chain string. Escape hatch for constructs not worth
  /// modelling; used sparingly and always with a comment at the call site.
  void addRaw(String chain) => _chains.add(
    FilterChain(filters: [Filter(chain)]),
  );

  String build() =>
      _chains.where((c) => c.build().isNotEmpty).map((c) => c.build()).join(';');

  /// Verifies every consumed label is produced somewhere, ignoring the
  /// `N:v` / `N:a` file-input pads. Cheap, and it turns a cryptic FFmpeg parse
  /// error into an assertion at the point the graph was written.
  List<String> validate() {
    final produced = <String>{};
    final consumed = <String>{};
    for (final chain in _chains) {
      produced.addAll(chain.outputs);
      consumed.addAll(chain.inputs);
    }
    final fileInput = RegExp(r'^\d+:[va]$');
    return consumed
        .where((label) => !fileInput.hasMatch(label) && !produced.contains(label))
        .toList();
  }

  @override
  String toString() => build();

  // ── Escaping ─────────────────────────────────────────────────────────
  //
  // FFmpeg's filter syntax has three nested levels of quoting. These helpers
  // cover the cases the app actually generates; anything else should be
  // added here with a test rather than escaped inline at a call site.

  /// Escapes a filter parameter value. `:` separates parameters and `,`
  /// separates filters, so both must be quoted inside a value.
  static String escapeValue(Object value) {
    final text = value is double ? formatDouble(value) : value.toString();
    if (!text.contains(RegExp(r"[:,\[\]';\\ ]"))) return text;
    final escaped = text
        .replaceAll('\\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(':', r'\:')
        .replaceAll(',', r'\,')
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]')
        .replaceAll(';', r'\;');
    return "'$escaped'";
  }

  /// Escapes a filesystem path used inside a filter (`movie=`, `lut3d=`).
  /// Paths are the most common source of graph parse failures because a
  /// perfectly ordinary Android path contains no special characters — until
  /// the user names a folder "Trip: Nepal".
  static String escapePath(String path) =>
      path.replaceAll('\\', r'\\').replaceAll(':', r'\:').replaceAll("'", r"\'");

  /// Escapes text for `drawtext`, which re-parses `%` and `\` after the
  /// filter-level unescaping.
  static String escapeDrawtext(String text) => text
      .replaceAll('\\', r'\\\\')
      .replaceAll(':', r'\:')
      .replaceAll("'", "\\'")
      .replaceAll('%', r'\%')
      .replaceAll('\n', r'\n');

  /// Trims float noise: FFmpeg does not need 17 significant digits, and short
  /// values keep the command line readable in logs.
  static String formatDouble(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toStringAsFixed(0);
    }
    return value
        .toStringAsFixed(6)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  /// ARGB int → FFmpeg colour literal `0xRRGGBB@A`.
  static String colorFrom(int argb) {
    final a = ((argb >> 24) & 0xFF) / 255.0;
    final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return a >= 0.999 ? '0x$rgb' : '0x$rgb@${formatDouble(a)}';
  }
}

/// Reusable filter constructors.
///
/// Keeping these together means the preview and the exporter cannot drift on
/// what, say, "blur at 0.5" means.
abstract final class Filters {
  static Filter scale(int width, int height, {String flags = 'bicubic'}) =>
      Filter('scale', {'w': width, 'h': height, 'flags': flags});

  /// Scales to fit inside [width]×[height] without distorting, then pads the
  /// remainder with [background]. This is the "fit" placement mode.
  static List<Filter> scaleToFit(
    int width,
    int height, {
    int background = 0xFF000000,
  }) => [
    Filter('scale', {
      'w': width,
      'h': height,
      'force_original_aspect_ratio': 'decrease',
      'flags': 'bicubic',
    }),
    Filter('pad', {
      'w': width,
      'h': height,
      'x': '(ow-iw)/2',
      'y': '(oh-ih)/2',
      'color': FilterGraph.colorFrom(background),
    }),
  ];

  /// Scales to cover [width]×[height] then centre-crops. The "fill" mode.
  static List<Filter> scaleToFill(int width, int height) => [
    Filter('scale', {
      'w': width,
      'h': height,
      'force_original_aspect_ratio': 'increase',
      'flags': 'bicubic',
    }),
    Filter('crop', {'w': width, 'h': height}),
  ];

  static Filter fps(int value) => Filter('fps')..arg('$value');

  static Filter setSar(String ratio) => Filter('setsar')..arg(ratio);

  /// Normalised insets → pixel crop. FFmpeg's crop wants pixels, and the
  /// expressions keep it resolution-independent.
  static Filter crop({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) => Filter('crop', {
    'w': 'iw*${FilterGraph.formatDouble(1 - left - right)}',
    'h': 'ih*${FilterGraph.formatDouble(1 - top - bottom)}',
    'x': 'iw*${FilterGraph.formatDouble(left)}',
    'y': 'ih*${FilterGraph.formatDouble(top)}',
  });

  static Filter hflip() => Filter('hflip');
  static Filter vflip() => Filter('vflip');

  /// Free-angle rotation. `ow`/`oh` grow the frame so corners are not clipped.
  static Filter rotate(double degrees, {int background = 0x00000000}) => Filter(
    'rotate',
    {
      'a': '${FilterGraph.formatDouble(degrees)}*PI/180',
      'ow': 'rotw(${FilterGraph.formatDouble(degrees)}*PI/180)',
      'oh': 'roth(${FilterGraph.formatDouble(degrees)}*PI/180)',
      'c': FilterGraph.colorFrom(background),
    },
  );

  /// 90° steps use `transpose`, which is exact and far cheaper than `rotate`.
  static List<Filter> rotateQuarter(int quarterTurns) {
    final turns = ((quarterTurns % 4) + 4) % 4;
    return switch (turns) {
      1 => [Filter('transpose')..arg('1')], // 90° clockwise
      2 => [Filter('transpose')..arg('1'), Filter('transpose')..arg('1')],
      3 => [Filter('transpose')..arg('2')], // 90° counter-clockwise
      _ => const [],
    };
  }

  /// Playback rate for video. `setpts` divides timestamps, so 2× speed is
  /// `PTS/2`.
  static Filter videoSpeed(double speed) =>
      Filter('setpts')..arg('${FilterGraph.formatDouble(1 / speed)}*PTS');

  /// Playback rate for audio. `atempo` only accepts 0.5–2.0 per instance, so
  /// larger changes are decomposed into a cascade — a real constraint that
  /// silently produces broken audio if ignored.
  static List<Filter> audioSpeed(double speed) {
    if ((speed - 1.0).abs() < 1e-6) return const [];
    final filters = <Filter>[];
    var remaining = speed.clamp(0.02, 100.0);
    while (remaining > 2.0) {
      filters.add(Filter('atempo')..arg('2.0'));
      remaining /= 2.0;
    }
    while (remaining < 0.5) {
      filters.add(Filter('atempo')..arg('0.5'));
      remaining /= 0.5;
    }
    filters.add(Filter('atempo')..arg(FilterGraph.formatDouble(remaining)));
    return filters;
  }

  /// Pitch shift in semitones, preserving duration: resample to change pitch,
  /// then `atempo` back to the original length.
  static List<Filter> pitchShift(double semitones, {int sampleRate = 48000}) {
    if (semitones.abs() < 0.01) return const [];
    final ratio = math.pow(2, semitones / 12).toDouble();
    return [
      Filter('asetrate')..arg('${(sampleRate * ratio).round()}'),
      ...audioSpeed(ratio),
      Filter('aresample')..arg('$sampleRate'),
    ];
  }

  static Filter reverseVideo() => Filter('reverse');
  static Filter reverseAudio() => Filter('areverse');

  static Filter volume(double gain) =>
      Filter('volume')..arg(FilterGraph.formatDouble(gain));

  static Filter audioFadeIn(Duration start, Duration duration) => Filter('afade', {
    't': 'in',
    'st': FilterGraph.formatDouble(start.inMicroseconds / 1e6),
    'd': FilterGraph.formatDouble(duration.inMicroseconds / 1e6),
  });

  static Filter audioFadeOut(Duration start, Duration duration) => Filter('afade', {
    't': 'out',
    'st': FilterGraph.formatDouble(start.inMicroseconds / 1e6),
    'd': FilterGraph.formatDouble(duration.inMicroseconds / 1e6),
  });

  static Filter videoFade({
    required bool fadeIn,
    required Duration start,
    required Duration duration,
    int color = 0xFF000000,
  }) => Filter('fade', {
    't': fadeIn ? 'in' : 'out',
    'st': FilterGraph.formatDouble(start.inMicroseconds / 1e6),
    'd': FilterGraph.formatDouble(duration.inMicroseconds / 1e6),
    'c': FilterGraph.colorFrom(color),
  });

  static Filter trim(Duration start, Duration end) => Filter('trim', {
    'start': FilterGraph.formatDouble(start.inMicroseconds / 1e6),
    'end': FilterGraph.formatDouble(end.inMicroseconds / 1e6),
  });

  static Filter atrim(Duration start, Duration end) => Filter('atrim', {
    'start': FilterGraph.formatDouble(start.inMicroseconds / 1e6),
    'end': FilterGraph.formatDouble(end.inMicroseconds / 1e6),
  });

  /// Rebases timestamps to zero. Required after every `trim`, or the segment
  /// keeps its original PTS and the concat lands it in the wrong place.
  static Filter resetPts() => Filter('setpts')..arg('PTS-STARTPTS');
  static Filter resetAudioPts() => Filter('asetpts')..arg('PTS-STARTPTS');

  /// Holds a single frame for [duration] — the freeze-frame primitive.
  static List<Filter> freezeFrame(Duration at, Duration duration, int fps) => [
    Filter('trim', {
      'start': FilterGraph.formatDouble(at.inMicroseconds / 1e6),
      'end': FilterGraph.formatDouble(
        (at.inMicroseconds + (1e6 / fps)) / 1e6,
      ),
    }),
    resetPts(),
    Filter('loop', {'loop': (duration.inMicroseconds * fps / 1e6).round(), 'size': 1}),
    resetPts(),
  ];

  static Filter overlay({
    String x = '0',
    String y = '0',
    String? enable,
    String format = 'auto',
  }) => Filter('overlay', {
    'x': x,
    'y': y,
    'format': format,
    'enable': ?enable,
  });

  static Filter blend(String mode, {double opacity = 1}) =>
      Filter('blend', {'all_mode': mode, 'all_opacity': opacity});

  /// Pads/silences an audio stream so every mixer input has the same length.
  static Filter audioPad(Duration total) => Filter('apad', {
    'whole_dur': FilterGraph.formatDouble(total.inMicroseconds / 1e6),
  });

  static Filter audioDelay(Duration delay) => Filter('adelay', {
    'delays': '${delay.inMilliseconds}',
    'all': 1,
  });

  static Filter mixAudio(int inputs, {String duration = 'longest'}) =>
      Filter('amix', {
        'inputs': inputs,
        'duration': duration,
        // Without this, amix divides by the input count and every added track
        // makes the mix quieter — the classic "my music vanished" bug.
        'normalize': 0,
      });

  static Filter concat({required int segments, required int v, required int a}) =>
      Filter('concat', {'n': segments, 'v': v, 'a': a});

  static Filter colorSource({
    required int color,
    required int width,
    required int height,
    required Duration duration,
    required int fps,
  }) => Filter('color', {
    'c': FilterGraph.colorFrom(color),
    's': '${width}x$height',
    'd': FilterGraph.formatDouble(duration.inMicroseconds / 1e6),
    'r': fps,
  });

  static Filter anullSource({
    required Duration duration,
    int sampleRate = 48000,
  }) => Filter('anullsrc', {
    'r': sampleRate,
    'cl': 'stereo',
    'd': FilterGraph.formatDouble(duration.inMicroseconds / 1e6),
  });

  const Filters._();
}
