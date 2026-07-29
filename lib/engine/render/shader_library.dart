/// Loads and caches compiled fragment shaders.
///
/// `FragmentProgram.fromAsset` is asynchronous and comparatively expensive, so
/// every program is loaded once at startup and reused. A shader that fails to
/// load (a driver quirk on an old GPU, a missing asset in a stripped build)
/// degrades to null and the compositor falls back to unfiltered playback rather
/// than showing a black frame.
library;

import 'dart:ui' as ui;

import '../../core/logging/app_logger.dart';
import '../../domain/entities/effect.dart';
import '../../domain/entities/transition.dart';
import '../effects/effect_catalog.dart';
import '../transitions/transition_catalog.dart';

class ShaderLibrary {
  ShaderLibrary();

  static const _log = Log('ShaderLibrary');

  final Map<String, ui.FragmentProgram> _programs = {};
  final Set<String> _failed = {};

  bool get isLoaded => _programs.isNotEmpty;
  int get loadedCount => _programs.length;

  /// Warms every shader the catalogues reference. Called once during startup;
  /// a failure here is logged and tolerated.
  Future<void> warmUp() async {
    final assets = <String>{
      'shaders/passthrough.frag',
      for (final spec in EffectCatalog.all)
        if (spec.shaderAsset != null) spec.shaderAsset!,
      for (final spec in TransitionCatalog.all)
        if (spec.shaderAsset != null) spec.shaderAsset!,
    };

    for (final asset in assets) {
      await load(asset);
    }
    _log.i(
      'shaders ready',
      fields: {'loaded': _programs.length, 'failed': _failed.length},
    );
  }

  Future<ui.FragmentProgram?> load(String asset) async {
    final cached = _programs[asset];
    if (cached != null) return cached;
    if (_failed.contains(asset)) return null;

    try {
      final program = await ui.FragmentProgram.fromAsset(asset);
      _programs[asset] = program;
      return program;
    } catch (e) {
      _failed.add(asset);
      _log.w('shader failed to load: $asset', error: e);
      return null;
    }
  }

  /// Synchronous lookup for the paint path, which cannot await.
  ui.FragmentProgram? program(String asset) => _programs[asset];

  ui.FragmentShader? shaderFor(EffectType type) {
    final asset = EffectCatalog.specFor(type)?.shaderAsset;
    if (asset == null) return null;
    return _programs[asset]?.fragmentShader();
  }

  ui.FragmentShader? transitionShaderFor(TransitionType type) {
    final asset = TransitionCatalog.specFor(type)?.shaderAsset;
    if (asset == null) return null;
    return _programs[asset]?.fragmentShader();
  }

  ui.FragmentShader? get passthrough =>
      _programs['shaders/passthrough.frag']?.fragmentShader();

  void dispose() {
    _programs.clear();
    _failed.clear();
  }
}

/// Packs effect parameters into a shader's float uniforms.
///
/// The uniform *order* here must match the declaration order in each `.frag`
/// file — `setFloat(i)` is positional, and there is no name lookup. Getting
/// this wrong produces a silently wrong image, so the mapping lives next to the
/// catalogue rather than being scattered across paint methods.
abstract final class ShaderUniforms {
  /// Applies uniforms for [effect] at [time]. Returns false when the effect
  /// has no GPU implementation and should be skipped.
  static bool apply({
    required ui.FragmentShader shader,
    required ResolvedEffect effect,
    required double width,
    required double height,
    required double timeSeconds,
  }) {
    // Slot 0/1 are always uSize.
    shader
      ..setFloat(0, width)
      ..setFloat(1, height);

    switch (effect.type) {
      case EffectType.blur:
      case EffectType.noiseReduction:
        shader
          ..setFloat(2, effect.value('radius', effect.value('strength', 0.5) * 20))
          ..setFloat(3, effect.intensity);
        return true;

      case EffectType.sharpen:
        shader
          ..setFloat(2, effect.value('amount', 0.8))
          ..setFloat(3, effect.intensity);
        return true;

      case EffectType.rgbSplit:
        shader
          ..setFloat(2, effect.value('offset', 8))
          ..setFloat(3, effect.value('angle'))
          ..setFloat(4, effect.intensity);
        return true;

      case EffectType.motionBlur:
        shader
          ..setFloat(2, effect.value('amount', 0.5))
          ..setFloat(3, effect.value('angle'))
          ..setFloat(4, effect.intensity);
        return true;

      case EffectType.glow:
      case EffectType.flash:
        shader
          ..setFloat(2, effect.value('amount', 0.5))
          ..setFloat(3, effect.value('threshold', 0.6))
          ..setFloat(4, effect.intensity);
        return true;

      case EffectType.vhs:
        shader
          ..setFloat(2, effect.value('amount', 0.6))
          ..setFloat(3, effect.value('scanlines', 0.5))
          ..setFloat(4, timeSeconds)
          ..setFloat(5, effect.intensity);
        return true;

      case EffectType.vintage:
      case EffectType.vignette:
        shader
          ..setFloat(2, effect.value('amount', 0.7))
          ..setFloat(3, effect.value('amount', 0.5))
          ..setFloat(4, effect.intensity);
        return true;

      case EffectType.filmGrain:
        shader
          ..setFloat(2, effect.value('amount', 0.35))
          ..setFloat(3, effect.value('size', 1))
          ..setFloat(4, timeSeconds)
          ..setFloat(5, effect.intensity);
        return true;

      case EffectType.cinematicLut:
        shader
          ..setFloat(2, 33) // cube edge; the strip texture must match
          ..setFloat(3, effect.value('mix', 1) * effect.intensity);
        return true;

      case EffectType.colorAdjust:
      case EffectType.chromaKey:
        // Handled with a ColorFilter/ColorMatrix rather than a shader — far
        // cheaper, and Skia can fold it into the existing paint.
        return false;
    }
  }

  /// Uniforms for a transition shader.
  static void applyTransition({
    required ui.FragmentShader shader,
    required Transition transition,
    required double progress,
    required double width,
    required double height,
  }) {
    shader
      ..setFloat(0, width)
      ..setFloat(1, height)
      ..setFloat(2, progress);

    switch (transition.type) {
      case TransitionType.fade:
        shader
          ..setFloat(3, 0) // mode: dissolve
          ..setFloat(4, 0)
          ..setFloat(5, 0);
      case TransitionType.slide:
        final (dx, dy) = _direction(transition.direction);
        shader
          ..setFloat(3, 1)
          ..setFloat(4, dx)
          ..setFloat(5, dy);
      case TransitionType.push:
        final (dx, dy) = _direction(transition.direction);
        shader
          ..setFloat(3, 2)
          ..setFloat(4, dx)
          ..setFloat(5, dy);
      case TransitionType.flash:
        shader
          ..setFloat(3, 3)
          ..setFloat(4, 0)
          ..setFloat(5, 0);
      case TransitionType.blur:
        shader
          ..setFloat(3, 0)
          ..setFloat(4, 0)
          ..setFloat(5, 0);
      case TransitionType.zoom:
        shader
          ..setFloat(3, 0)
          ..setFloat(4, transition.intensity);
      case TransitionType.spin:
        shader
          ..setFloat(3, 1)
          ..setFloat(4, transition.intensity);
      case TransitionType.warp:
        shader
          ..setFloat(3, 2)
          ..setFloat(4, transition.intensity);
      case TransitionType.ripple:
        shader.setFloat(3, transition.intensity);
      case TransitionType.glitch:
        shader.setFloat(3, transition.intensity);
      case TransitionType.none:
        break;
    }
  }

  static (double dx, double dy) _direction(TransitionDirection direction) =>
      switch (direction) {
        TransitionDirection.left => (-1, 0),
        TransitionDirection.right => (1, 0),
        TransitionDirection.up => (0, -1),
        TransitionDirection.down => (0, 1),
      };

  const ShaderUniforms._();
}
