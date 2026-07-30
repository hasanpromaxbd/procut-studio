/// Video scopes computed from the live preview.
///
/// ## Why the preview and not the source
///
/// There is no pixel buffer behind a platform video texture, so the only
/// picture this app can actually measure is the one on screen — the same
/// `RepaintBoundary` the eyedropper rasterises. That means the scopes read the
/// *graded* image, including every effect, which is what a colourist wants
/// anyway. It also means they are limited by the preview's own accuracy, and
/// the UI says so rather than implying broadcast-grade measurement.
///
/// ## Why it samples on demand
///
/// Rasterising every frame would cost a full readback per frame and drop the
/// preview well below its 60 fps target. A scope is read while looking at one
/// frame, so sampling is triggered explicitly and after the playhead settles.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import 'eyedropper_controller.dart';

/// Which scope the panel is showing. They all come from one pixel pass, so
/// switching is free — the enum only selects what gets painted.
enum ScopeKind {
  histogram('Histogram', 'How many pixels sit at each level'),
  waveform('Waveform', 'Level against horizontal position'),
  parade('RGB parade', 'The three channels side by side'),
  vectorscope('Vectorscope', 'Hue and saturation, ignoring brightness');

  const ScopeKind(this.label, this.blurb);
  final String label;
  final String blurb;
}

/// Resolution of the generated scope textures. 256 matches the 8-bit level
/// range exactly, so a level maps to a row without rounding.
const int _scopeSize = 256;

/// Horizontal resolution of the sampled frame. Enough columns for a waveform
/// to read correctly, small enough that the readback and the histogram pass
/// stay well inside a frame budget.
const int _sampleWidth = 256;

@immutable
class ScopesData {
  const ScopesData({
    required this.luma,
    required this.red,
    required this.green,
    required this.blue,
    required this.waveform,
    required this.parade,
    required this.vectorscope,
    required this.clippedHighlights,
    required this.clippedShadows,
    required this.sampledPixels,
  });

  /// 256 bins each, counts of pixels at every level.
  final Int32List luma;
  final Int32List red;
  final Int32List green;
  final Int32List blue;

  /// Pre-rendered scope textures. Null until the first sample completes.
  final ui.Image? waveform;
  final ui.Image? parade;
  final ui.Image? vectorscope;

  /// Fraction of pixels pinned at 255 or 0 — the numbers that decide whether
  /// detail has actually been lost.
  final double clippedHighlights;
  final double clippedShadows;

  final int sampledPixels;

  int get peakBin {
    var peak = 1;
    for (final v in luma) {
      if (v > peak) peak = v;
    }
    return peak;
  }

  void dispose() {
    waveform?.dispose();
    parade?.dispose();
    vectorscope?.dispose();
  }
}

@immutable
class ScopesState {
  const ScopesState({
    this.kind = ScopeKind.histogram,
    this.data,
    this.isSampling = false,
    this.isLive = true,
    this.error,
  });

  final ScopeKind kind;
  final ScopesData? data;
  final bool isSampling;

  /// Whether a new sample is taken when the picture changes. Off means the
  /// last reading is held, so two frames can be compared.
  final bool isLive;

  final String? error;

  ScopesState copyWith({
    ScopeKind? kind,
    ScopesData? data,
    bool? isSampling,
    bool? isLive,
    String? error,
    bool clearError = false,
  }) => ScopesState(
    kind: kind ?? this.kind,
    data: data ?? this.data,
    isSampling: isSampling ?? this.isSampling,
    isLive: isLive ?? this.isLive,
    error: clearError ? null : (error ?? this.error),
  );
}

final scopesProvider = NotifierProvider<ScopesController, ScopesState>(
  ScopesController.new,
);

class ScopesController extends Notifier<ScopesState> {
  static const _log = Log('Scopes');

  Timer? _settle;
  bool _busy = false;

  @override
  ScopesState build() {
    ref.onDispose(() {
      _settle?.cancel();
      state.data?.dispose();
    });
    return const ScopesState();
  }

  void setKind(ScopeKind kind) => state = state.copyWith(kind: kind);

  void setLive({required bool live}) {
    state = state.copyWith(isLive: live);
    if (live) requestSample();
  }

  /// Asks for a fresh reading once the picture has stopped changing.
  ///
  /// Debounced rather than immediate: scrubbing fires this on every frame, and
  /// a readback per frame is exactly what makes a scope panel feel like it has
  /// broken the editor.
  void requestSample({
    Duration settle = const Duration(milliseconds: 180),
  }) {
    _settle?.cancel();
    _settle = Timer(settle, () => unawaited(sampleNow()));
  }

  /// Reads the preview and recomputes every scope.
  Future<void> sampleNow() async {
    if (_busy) return;
    final context = ref.read(eyedropperProvider.notifier).previewKey
        .currentContext;
    final boundary = context?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      state = state.copyWith(error: 'The preview is not on screen.');
      return;
    }
    if (boundary.size.isEmpty) return;

    _busy = true;
    state = state.copyWith(isSampling: true, clearError: true);
    try {
      // Rasterise small. The scopes summarise a distribution, and a quarter of
      // a megapixel describes it just as well as two — at a twentieth of the
      // readback cost.
      final ratio = (_sampleWidth / boundary.size.width).clamp(0.05, 1.0);
      final image = await boundary.toImage(pixelRatio: ratio);
      Uint8List pixels;
      int width;
      int height;
      try {
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (data == null) {
          state = state.copyWith(
            isSampling: false,
            error: 'The preview could not be read.',
          );
          return;
        }
        pixels = data.buffer.asUint8List();
        width = image.width;
        height = image.height;
      } finally {
        image.dispose();
      }

      final raw = await compute(_analyse, _AnalysisRequest(pixels, width, height));
      final built = await _buildTextures(raw);

      state.data?.dispose();
      state = state.copyWith(data: built, isSampling: false, clearError: true);
    } catch (e) {
      _log.w('scope sample failed', error: e);
      state = state.copyWith(
        isSampling: false,
        error: 'Could not measure this frame.',
      );
    } finally {
      _busy = false;
    }
  }

  Future<ScopesData> _buildTextures(_Analysis raw) async => ScopesData(
    luma: raw.luma,
    red: raw.red,
    green: raw.green,
    blue: raw.blue,
    waveform: await _toImage(raw.waveform, _scopeSize, _scopeSize),
    parade: await _toImage(raw.parade, _scopeSize * 3, _scopeSize),
    vectorscope: await _toImage(raw.vectorscope, _vectorSize, _vectorSize),
    clippedHighlights: raw.sampled == 0 ? 0 : raw.clippedHigh / raw.sampled,
    clippedShadows: raw.sampled == 0 ? 0 : raw.clippedLow / raw.sampled,
    sampledPixels: raw.sampled,
  );

  static Future<ui.Image> _toImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

/// Vectorscope resolution. Smaller than the others because it is a 2-D
/// histogram: at 256² most cells would hold a single pixel and read as noise.
const int _vectorSize = 192;

class _AnalysisRequest {
  const _AnalysisRequest(this.pixels, this.width, this.height);
  final Uint8List pixels;
  final int width;
  final int height;
}

class _Analysis {
  _Analysis({
    required this.luma,
    required this.red,
    required this.green,
    required this.blue,
    required this.waveform,
    required this.parade,
    required this.vectorscope,
    required this.clippedHigh,
    required this.clippedLow,
    required this.sampled,
  });

  final Int32List luma;
  final Int32List red;
  final Int32List green;
  final Int32List blue;
  final Uint8List waveform;
  final Uint8List parade;
  final Uint8List vectorscope;
  final int clippedHigh;
  final int clippedLow;
  final int sampled;
}

/// One pass over the pixels producing every scope.
///
/// Runs on a background isolate — a quarter-megapixel loop is a few
/// milliseconds, which is a visible hitch if it lands on the frame the user is
/// scrubbing.
_Analysis _analyse(_AnalysisRequest request) {
  final pixels = request.pixels;
  final width = request.width;
  final height = request.height;

  final luma = Int32List(256);
  final red = Int32List(256);
  final green = Int32List(256);
  final blue = Int32List(256);

  // Hit counts first, intensity afterwards. Writing straight to RGBA would
  // make one stray pixel as bright as a solid edge.
  final waveHits = Int32List(_scopeSize * _scopeSize);
  final paradeHits = Int32List(_scopeSize * 3 * _scopeSize);
  final vectorHits = Int32List(_vectorSize * _vectorSize);

  const paradeStride = _scopeSize * 3;

  var clippedHigh = 0;
  var clippedLow = 0;
  var sampled = 0;

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      // Transparent pixels are letterbox, not picture.
      if (pixels[offset + 3] < 8) continue;

      final r = pixels[offset];
      final g = pixels[offset + 1];
      final b = pixels[offset + 2];
      sampled++;

      // Rec. 709 luma, matching what the export encodes.
      final l = (0.2126 * r + 0.7152 * g + 0.0722 * b).round().clamp(0, 255);

      luma[l]++;
      red[r]++;
      green[g]++;
      blue[b]++;

      if (r >= 254 && g >= 254 && b >= 254) clippedHigh++;
      if (r <= 1 && g <= 1 && b <= 1) clippedLow++;

      // Level on the vertical axis, horizontal position preserved, so the
      // trace lines up with the picture above it.
      final column = (x * _scopeSize) ~/ width;
      waveHits[(_scopeSize - 1 - l) * _scopeSize + column]++;

      paradeHits[(_scopeSize - 1 - r) * paradeStride + column]++;
      paradeHits[(_scopeSize - 1 - g) * paradeStride + _scopeSize + column]++;
      paradeHits[(_scopeSize - 1 - b) * paradeStride + _scopeSize * 2 + column]++;

      // Chroma only. Cb/Cr run ±0.5 of full scale; Cr is flipped because
      // screen Y grows downwards.
      final cb = -0.1146 * r - 0.3854 * g + 0.5 * b;
      final cr = 0.5 * r - 0.4542 * g - 0.0458 * b;
      final vx = ((cb / 255 + 0.5) * (_vectorSize - 1))
          .round()
          .clamp(0, _vectorSize - 1);
      final vy = ((0.5 - cr / 255) * (_vectorSize - 1))
          .round()
          .clamp(0, _vectorSize - 1);
      vectorHits[vy * _vectorSize + vx]++;
    }
  }

  return _Analysis(
    luma: luma,
    red: red,
    green: green,
    blue: blue,
    waveform: _hitsToRgba(waveHits, const _Tint(0.85, 1.0, 0.9)),
    parade: _paradeToRgba(paradeHits),
    vectorscope: _hitsToRgba(vectorHits, const _Tint(0.55, 0.95, 0.75)),
    clippedHigh: clippedHigh,
    clippedLow: clippedLow,
    sampled: sampled,
  );
}

class _Tint {
  const _Tint(this.r, this.g, this.b);
  final double r;
  final double g;
  final double b;
}

/// Maps hit counts to intensity on a square-root curve — the same response a
/// hardware scope's phosphor gives you, and the reason a thin trace stays
/// visible beside a saturated one. Linear leaves everything but the brightest
/// band invisible.
Uint8List _hitsToRgba(Int32List hits, _Tint tint) {
  var peak = 1;
  for (final v in hits) {
    if (v > peak) peak = v;
  }
  final out = Uint8List(hits.length * 4);
  for (var i = 0; i < hits.length; i++) {
    final hit = hits[i];
    if (hit == 0) continue;
    final value = 255 * math.sqrt(hit / peak);
    final o = i * 4;
    out[o] = (value * tint.r).round().clamp(0, 255);
    out[o + 1] = (value * tint.g).round().clamp(0, 255);
    out[o + 2] = (value * tint.b).round().clamp(0, 255);
    out[o + 3] = 255;
  }
  return out;
}

/// Same curve, but each third of the width is tinted to its own channel.
Uint8List _paradeToRgba(Int32List hits) {
  const width = _scopeSize * 3;
  var peak = 1;
  for (final v in hits) {
    if (v > peak) peak = v;
  }
  final out = Uint8List(hits.length * 4);
  for (var i = 0; i < hits.length; i++) {
    final hit = hits[i];
    if (hit == 0) continue;
    final value = (255 * math.sqrt(hit / peak)).round().clamp(0, 255);
    // A little of the other two channels keeps the trace from reading as a
    // flat silhouette on an OLED panel.
    final dim = (value * 0.12).round();
    final channel = (i % width) ~/ _scopeSize;
    final o = i * 4;
    out[o] = channel == 0 ? value : dim;
    out[o + 1] = channel == 1 ? value : dim;
    out[o + 2] = channel == 2 ? value : dim;
    out[o + 3] = 255;
  }
  return out;
}
