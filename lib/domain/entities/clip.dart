/// The timeline's atomic unit.
///
/// [Clip] is a sealed hierarchy so that every renderer, exporter and inspector
/// gets a compile-time exhaustiveness check. Adding a new clip kind breaks the
/// build in exactly the places that must handle it — which is the point.
library;

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/time_utils.dart';
import 'effect.dart';
import 'keyframe.dart';
import 'text_style_spec.dart';
import 'transform2d.dart';
import 'transition.dart';

enum ClipKind {
  video('video'),
  audio('audio'),
  image('image'),
  text('text'),
  sticker('sticker');

  const ClipKind(this.id);
  final String id;

  static ClipKind fromId(String? id) =>
      ClipKind.values.firstWhere((e) => e.id == id, orElse: () => ClipKind.video);
}

sealed class Clip {
  const Clip({
    required this.id,
    required this.trackId,
    required this.start,
    required this.duration,
    this.label,
    this.locked = false,
    this.enabled = true,
    this.transform = Transform2D.identity,
    this.effects = const [],
    this.outTransition,
  });

  final String id;
  final String trackId;

  /// Position of the clip's first frame on the timeline.
  final Duration start;

  /// Length **on the timeline**. For a media clip this is already
  /// speed-adjusted: a 10s source at 2× has a 5s timeline duration.
  final Duration duration;

  final String? label;

  /// Locked clips ignore drag/trim gestures but still render.
  final bool locked;

  /// Disabled clips are skipped by both the preview and the exporter.
  final bool enabled;

  final Transform2D transform;
  final List<Effect> effects;

  /// Transition out of this clip into the next one on the same track.
  final Transition? outTransition;

  ClipKind get kind;

  Duration get end => start + duration;

  /// Half-open interval `[start, end)` — a clip ending exactly where the next
  /// begins must not be reported as overlapping.
  bool containsTime(Duration t) => t >= start && t < end;

  bool overlaps(Clip other) => start < other.end && other.start < end;

  /// Converts a timeline instant to an offset within this clip, which is the
  /// coordinate space keyframes and effect animation live in.
  Duration localTime(Duration timelineTime) => timelineTime - start;

  List<Effect> get activeEffects =>
      effects.where((e) => e.enabled).toList()..sort(
        (a, b) => _stageOf(a.type).order.compareTo(_stageOf(b.type).order),
      );

  bool get hasTransition => outTransition?.isActive ?? false;

  Clip copyWithBase({
    Duration? start,
    Duration? duration,
    String? trackId,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  });

  Map<String, dynamic> toJson();

  Map<String, dynamic> baseJson() => {
    'id': id,
    'trackId': trackId,
    'kind': kind.id,
    'startUs': start.inMicroseconds,
    'durUs': duration.inMicroseconds,
    if (label != null) 'label': label,
    if (locked) 'locked': true,
    if (!enabled) 'off': true,
    if (!transform.isIdentity) 'transform': transform.toJson(),
    if (effects.isNotEmpty)
      'effects': effects.map((e) => e.toJson()).toList(),
    if (outTransition != null) 'outTransition': outTransition!.toJson(),
  };

  static Clip fromJson(Map<String, dynamic> json) =>
      switch (ClipKind.fromId(json['kind'] as String?)) {
        ClipKind.video => VideoClip.fromJson(json),
        ClipKind.audio => AudioClip.fromJson(json),
        ClipKind.image => ImageClip.fromJson(json),
        ClipKind.text => TextClip.fromJson(json),
        ClipKind.sticker => StickerClip.fromJson(json),
      };

  static EffectStage _stageOf(EffectType type) => switch (type) {
    EffectType.cinematicLut ||
    EffectType.colorAdjust ||
    EffectType.chromaKey => EffectStage.color,
    EffectType.blur ||
    EffectType.motionBlur ||
    EffectType.sharpen ||
    EffectType.noiseReduction ||
    EffectType.glow ||
    EffectType.flash => EffectStage.stylise,
    EffectType.vhs ||
    EffectType.rgbSplit ||
    EffectType.vintage ||
    EffectType.filmGrain ||
    EffectType.vignette => EffectStage.texture,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Clip && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Common behaviour for clips backed by a [MediaAsset] on disk.
sealed class MediaClip extends Clip {
  const MediaClip({
    required super.id,
    required super.trackId,
    required super.start,
    required super.duration,
    required this.assetId,
    this.sourceIn = Duration.zero,
    this.speed = 1.0,
    this.reversed = false,
    super.label,
    super.locked,
    super.enabled,
    super.transform,
    super.effects,
    super.outTransition,
  });

  final String assetId;

  /// Offset into the source file where playback begins.
  final Duration sourceIn;

  /// Playback rate, [AppConstants.minClipSpeed] … [AppConstants.maxClipSpeed].
  final double speed;

  final bool reversed;

  /// How much source material this clip consumes — timeline duration × speed.
  Duration get sourceDuration => TimeUtils.unscale(duration, speed);

  Duration get sourceOut => sourceIn + sourceDuration;

  bool get isSpeedAltered => (speed - 1.0).abs() > 1e-6;

  /// Maps a timeline instant to a source-file timestamp, accounting for both
  /// speed and reversal. This is the function the exporter and the preview
  /// seek logic must agree on exactly, or audio drifts from picture.
  Duration sourceTimeAt(Duration timelineTime) {
    final local = TimeUtils.clamp(
      localTime(timelineTime),
      Duration.zero,
      duration,
    );
    final consumed = TimeUtils.unscale(local, speed);
    return reversed ? sourceOut - consumed : sourceIn + consumed;
  }

  Map<String, dynamic> mediaJson() => {
    ...baseJson(),
    'assetId': assetId,
    'inUs': sourceIn.inMicroseconds,
    if (speed != 1.0) 'speed': speed,
    if (reversed) 'reversed': true,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// Video
// ─────────────────────────────────────────────────────────────────────────

final class VideoClip extends MediaClip {
  const VideoClip({
    required super.id,
    required super.trackId,
    required super.start,
    required super.duration,
    required super.assetId,
    super.sourceIn,
    super.speed,
    super.reversed,
    super.label,
    super.locked,
    super.enabled,
    super.transform,
    super.effects,
    super.outTransition,
    this.volume = const AnimatableDouble.constant(1),
    this.muted = false,
    this.audioFadeIn = Duration.zero,
    this.audioFadeOut = Duration.zero,
    this.freezeFrameAt,
  });

  /// Animatable so the user can draw a volume envelope (ducking under a
  /// voice-over, for example) rather than only setting one level.
  final AnimatableDouble volume;
  final bool muted;
  final Duration audioFadeIn;
  final Duration audioFadeOut;

  /// When set, the clip shows this single source frame for its whole duration.
  /// That is the entire freeze-frame feature — no separate clip kind needed.
  final Duration? freezeFrameAt;

  bool get isFrozen => freezeFrameAt != null;

  @override
  ClipKind get kind => ClipKind.video;

  @override
  Duration sourceTimeAt(Duration timelineTime) =>
      freezeFrameAt ?? super.sourceTimeAt(timelineTime);

  double volumeAt(Duration timelineTime) {
    if (muted) return 0;
    final local = localTime(timelineTime);
    var gain = volume.valueAt(local).clamp(0.0, 2.0);
    gain *= _fadeGain(local, duration, audioFadeIn, audioFadeOut);
    return gain;
  }

  VideoClip copyWith({
    String? id,
    String? trackId,
    Duration? start,
    Duration? duration,
    String? assetId,
    Duration? sourceIn,
    double? speed,
    bool? reversed,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
    AnimatableDouble? volume,
    bool? muted,
    Duration? audioFadeIn,
    Duration? audioFadeOut,
    Duration? freezeFrameAt,
    bool clearFreezeFrame = false,
  }) => VideoClip(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    assetId: assetId ?? this.assetId,
    sourceIn: sourceIn ?? this.sourceIn,
    speed: speed ?? this.speed,
    reversed: reversed ?? this.reversed,
    label: label ?? this.label,
    locked: locked ?? this.locked,
    enabled: enabled ?? this.enabled,
    transform: transform ?? this.transform,
    effects: effects ?? this.effects,
    outTransition: clearTransition ? null : (outTransition ?? this.outTransition),
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    audioFadeIn: audioFadeIn ?? this.audioFadeIn,
    audioFadeOut: audioFadeOut ?? this.audioFadeOut,
    freezeFrameAt: clearFreezeFrame ? null : (freezeFrameAt ?? this.freezeFrameAt),
  );

  @override
  VideoClip copyWithBase({
    Duration? start,
    Duration? duration,
    String? trackId,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => copyWith(
    start: start,
    duration: duration,
    trackId: trackId,
    label: label,
    locked: locked,
    enabled: enabled,
    transform: transform,
    effects: effects,
    outTransition: outTransition,
    clearTransition: clearTransition,
  );

  @override
  Map<String, dynamic> toJson() => {
    ...mediaJson(),
    'volume': volume.toJson(),
    if (muted) 'muted': true,
    if (audioFadeIn > Duration.zero) 'fadeInUs': audioFadeIn.inMicroseconds,
    if (audioFadeOut > Duration.zero) 'fadeOutUs': audioFadeOut.inMicroseconds,
    if (freezeFrameAt != null) 'freezeUs': freezeFrameAt!.inMicroseconds,
  };

  factory VideoClip.fromJson(Map<String, dynamic> json) => VideoClip(
    id: json['id'] as String,
    trackId: json['trackId'] as String,
    start: Duration(microseconds: (json['startUs'] as num?)?.toInt() ?? 0),
    duration: Duration(microseconds: (json['durUs'] as num?)?.toInt() ?? 0),
    assetId: json['assetId'] as String? ?? '',
    sourceIn: Duration(microseconds: (json['inUs'] as num?)?.toInt() ?? 0),
    speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
    reversed: json['reversed'] as bool? ?? false,
    label: json['label'] as String?,
    locked: json['locked'] as bool? ?? false,
    enabled: !(json['off'] as bool? ?? false),
    transform: Transform2D.fromJson(
      (json['transform'] as Map?)?.cast<String, dynamic>(),
    ),
    effects: _effectsFromJson(json),
    outTransition: _transitionFromJson(json),
    volume: AnimatableDouble.fromJson(json['volume'], fallback: 1),
    muted: json['muted'] as bool? ?? false,
    audioFadeIn: Duration(microseconds: (json['fadeInUs'] as num?)?.toInt() ?? 0),
    audioFadeOut: Duration(microseconds: (json['fadeOutUs'] as num?)?.toInt() ?? 0),
    freezeFrameAt: json['freezeUs'] == null
        ? null
        : Duration(microseconds: (json['freezeUs'] as num).toInt()),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Audio
// ─────────────────────────────────────────────────────────────────────────

final class AudioClip extends MediaClip {
  const AudioClip({
    required super.id,
    required super.trackId,
    required super.start,
    required super.duration,
    required super.assetId,
    super.sourceIn,
    super.speed,
    super.reversed,
    super.label,
    super.locked,
    super.enabled,
    super.effects,
    super.outTransition,
    this.volume = const AnimatableDouble.constant(1),
    this.muted = false,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.pitchSemitones = 0,
    this.preservePitch = true,
    this.equalizer = const EqualizerSettings(),
    this.isVoiceOver = false,
  });

  final AnimatableDouble volume;
  final bool muted;
  final Duration fadeIn;
  final Duration fadeOut;

  /// −12 … +12 semitones.
  final double pitchSemitones;

  /// When true, changing [speed] does not change perceived pitch — FFmpeg's
  /// `atempo` rather than a raw sample-rate change.
  final bool preservePitch;

  final EqualizerSettings equalizer;

  /// Marks clips captured by the in-app recorder, so the UI can offer voice
  /// isolation and noise reduction up front.
  final bool isVoiceOver;

  @override
  ClipKind get kind => ClipKind.audio;

  double volumeAt(Duration timelineTime) {
    if (muted) return 0;
    final local = localTime(timelineTime);
    return (volume.valueAt(local).clamp(0.0, 2.0)) *
        _fadeGain(local, duration, fadeIn, fadeOut);
  }

  AudioClip copyWith({
    String? id,
    String? trackId,
    Duration? start,
    Duration? duration,
    String? assetId,
    Duration? sourceIn,
    double? speed,
    bool? reversed,
    String? label,
    bool? locked,
    bool? enabled,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
    AnimatableDouble? volume,
    bool? muted,
    Duration? fadeIn,
    Duration? fadeOut,
    double? pitchSemitones,
    bool? preservePitch,
    EqualizerSettings? equalizer,
    bool? isVoiceOver,
  }) => AudioClip(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    assetId: assetId ?? this.assetId,
    sourceIn: sourceIn ?? this.sourceIn,
    speed: speed ?? this.speed,
    reversed: reversed ?? this.reversed,
    label: label ?? this.label,
    locked: locked ?? this.locked,
    enabled: enabled ?? this.enabled,
    effects: effects ?? this.effects,
    outTransition: clearTransition ? null : (outTransition ?? this.outTransition),
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    fadeIn: fadeIn ?? this.fadeIn,
    fadeOut: fadeOut ?? this.fadeOut,
    pitchSemitones: pitchSemitones ?? this.pitchSemitones,
    preservePitch: preservePitch ?? this.preservePitch,
    equalizer: equalizer ?? this.equalizer,
    isVoiceOver: isVoiceOver ?? this.isVoiceOver,
  );

  @override
  AudioClip copyWithBase({
    Duration? start,
    Duration? duration,
    String? trackId,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => copyWith(
    start: start,
    duration: duration,
    trackId: trackId,
    label: label,
    locked: locked,
    enabled: enabled,
    effects: effects,
    outTransition: outTransition,
    clearTransition: clearTransition,
  );

  @override
  Map<String, dynamic> toJson() => {
    ...mediaJson(),
    'volume': volume.toJson(),
    if (muted) 'muted': true,
    if (fadeIn > Duration.zero) 'fadeInUs': fadeIn.inMicroseconds,
    if (fadeOut > Duration.zero) 'fadeOutUs': fadeOut.inMicroseconds,
    if (pitchSemitones != 0) 'pitch': pitchSemitones,
    if (!preservePitch) 'preservePitch': false,
    if (!equalizer.isFlat) 'eq': equalizer.toJson(),
    if (isVoiceOver) 'vo': true,
  };

  factory AudioClip.fromJson(Map<String, dynamic> json) => AudioClip(
    id: json['id'] as String,
    trackId: json['trackId'] as String,
    start: Duration(microseconds: (json['startUs'] as num?)?.toInt() ?? 0),
    duration: Duration(microseconds: (json['durUs'] as num?)?.toInt() ?? 0),
    assetId: json['assetId'] as String? ?? '',
    sourceIn: Duration(microseconds: (json['inUs'] as num?)?.toInt() ?? 0),
    speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
    reversed: json['reversed'] as bool? ?? false,
    label: json['label'] as String?,
    locked: json['locked'] as bool? ?? false,
    enabled: !(json['off'] as bool? ?? false),
    effects: _effectsFromJson(json),
    outTransition: _transitionFromJson(json),
    volume: AnimatableDouble.fromJson(json['volume'], fallback: 1),
    muted: json['muted'] as bool? ?? false,
    fadeIn: Duration(microseconds: (json['fadeInUs'] as num?)?.toInt() ?? 0),
    fadeOut: Duration(microseconds: (json['fadeOutUs'] as num?)?.toInt() ?? 0),
    pitchSemitones: (json['pitch'] as num?)?.toDouble() ?? 0,
    preservePitch: json['preservePitch'] as bool? ?? true,
    equalizer: EqualizerSettings.fromJson(
      (json['eq'] as Map?)?.cast<String, dynamic>(),
    ),
    isVoiceOver: json['vo'] as bool? ?? false,
  );
}

/// Five-band EQ. Bands are fixed frequencies so the UI is a simple set of
/// sliders and the FFmpeg filter chain is deterministic.
@immutable
class EqualizerSettings {
  const EqualizerSettings({
    this.bass = 0,
    this.lowMid = 0,
    this.mid = 0,
    this.highMid = 0,
    this.treble = 0,
  });

  /// Gains in dB, −15 … +15.
  final double bass; // 100 Hz
  final double lowMid; // 400 Hz
  final double mid; // 1 kHz
  final double highMid; // 4 kHz
  final double treble; // 12 kHz

  static const List<int> frequencies = [100, 400, 1000, 4000, 12000];

  List<double> get gains => [bass, lowMid, mid, highMid, treble];

  bool get isFlat => gains.every((g) => g.abs() < 0.01);

  EqualizerSettings copyWithBand(int index, double gain) => EqualizerSettings(
    bass: index == 0 ? gain : bass,
    lowMid: index == 1 ? gain : lowMid,
    mid: index == 2 ? gain : mid,
    highMid: index == 3 ? gain : highMid,
    treble: index == 4 ? gain : treble,
  );

  Map<String, dynamic> toJson() => {
    'bass': bass,
    'lowMid': lowMid,
    'mid': mid,
    'highMid': highMid,
    'treble': treble,
  };

  factory EqualizerSettings.fromJson(Map<String, dynamic>? json) =>
      json == null
          ? const EqualizerSettings()
          : EqualizerSettings(
              bass: (json['bass'] as num?)?.toDouble() ?? 0,
              lowMid: (json['lowMid'] as num?)?.toDouble() ?? 0,
              mid: (json['mid'] as num?)?.toDouble() ?? 0,
              highMid: (json['highMid'] as num?)?.toDouble() ?? 0,
              treble: (json['treble'] as num?)?.toDouble() ?? 0,
            );
}

// ─────────────────────────────────────────────────────────────────────────
// Image
// ─────────────────────────────────────────────────────────────────────────

final class ImageClip extends MediaClip {
  const ImageClip({
    required super.id,
    required super.trackId,
    required super.start,
    required super.duration,
    required super.assetId,
    super.label,
    super.locked,
    super.enabled,
    super.transform,
    super.effects,
    super.outTransition,
  }) : super(sourceIn: Duration.zero, speed: 1.0, reversed: false);

  @override
  ClipKind get kind => ClipKind.image;

  /// A still has no timeline within itself.
  @override
  Duration sourceTimeAt(Duration timelineTime) => Duration.zero;

  ImageClip copyWith({
    String? id,
    String? trackId,
    Duration? start,
    Duration? duration,
    String? assetId,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => ImageClip(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    assetId: assetId ?? this.assetId,
    label: label ?? this.label,
    locked: locked ?? this.locked,
    enabled: enabled ?? this.enabled,
    transform: transform ?? this.transform,
    effects: effects ?? this.effects,
    outTransition: clearTransition ? null : (outTransition ?? this.outTransition),
  );

  @override
  ImageClip copyWithBase({
    Duration? start,
    Duration? duration,
    String? trackId,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => copyWith(
    start: start,
    duration: duration,
    trackId: trackId,
    label: label,
    locked: locked,
    enabled: enabled,
    transform: transform,
    effects: effects,
    outTransition: outTransition,
    clearTransition: clearTransition,
  );

  @override
  Map<String, dynamic> toJson() => mediaJson();

  factory ImageClip.fromJson(Map<String, dynamic> json) => ImageClip(
    id: json['id'] as String,
    trackId: json['trackId'] as String,
    start: Duration(microseconds: (json['startUs'] as num?)?.toInt() ?? 0),
    duration: Duration(microseconds: (json['durUs'] as num?)?.toInt() ?? 0),
    assetId: json['assetId'] as String? ?? '',
    label: json['label'] as String?,
    locked: json['locked'] as bool? ?? false,
    enabled: !(json['off'] as bool? ?? false),
    transform: Transform2D.fromJson(
      (json['transform'] as Map?)?.cast<String, dynamic>(),
    ),
    effects: _effectsFromJson(json),
    outTransition: _transitionFromJson(json),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Text
// ─────────────────────────────────────────────────────────────────────────

final class TextClip extends Clip {
  const TextClip({
    required super.id,
    required super.trackId,
    required super.start,
    required super.duration,
    required this.text,
    this.style = const TextStyleSpec(),
    this.animationIn = TextAnimation.none,
    this.animationOut = TextAnimation.none,
    this.animationDuration = const Duration(milliseconds: 600),
    this.isSubtitle = false,
    super.label,
    super.locked,
    super.enabled,
    super.transform,
    super.effects,
    super.outTransition,
  });

  final String text;
  final TextStyleSpec style;
  final TextAnimation animationIn;
  final TextAnimation animationOut;
  final Duration animationDuration;

  /// Subtitle clips are generated by auto-caption and are edited as a group.
  final bool isSubtitle;

  @override
  ClipKind get kind => ClipKind.text;

  String get displayText => style.allCaps ? text.toUpperCase() : text;

  /// 0..1 progress of the entry animation at [timelineTime].
  double animationInProgress(Duration timelineTime) {
    if (animationIn == TextAnimation.none) return 1;
    final local = localTime(timelineTime);
    if (local <= Duration.zero) return 0;
    if (local >= animationDuration) return 1;
    return local.inMicroseconds / animationDuration.inMicroseconds;
  }

  /// 0..1 progress of the exit animation; 0 means "not started".
  double animationOutProgress(Duration timelineTime) {
    if (animationOut == TextAnimation.none) return 0;
    final remaining = end - timelineTime;
    if (remaining >= animationDuration) return 0;
    if (remaining <= Duration.zero) return 1;
    return 1 - remaining.inMicroseconds / animationDuration.inMicroseconds;
  }

  TextClip copyWith({
    String? id,
    String? trackId,
    Duration? start,
    Duration? duration,
    String? text,
    TextStyleSpec? style,
    TextAnimation? animationIn,
    TextAnimation? animationOut,
    Duration? animationDuration,
    bool? isSubtitle,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => TextClip(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    text: text ?? this.text,
    style: style ?? this.style,
    animationIn: animationIn ?? this.animationIn,
    animationOut: animationOut ?? this.animationOut,
    animationDuration: animationDuration ?? this.animationDuration,
    isSubtitle: isSubtitle ?? this.isSubtitle,
    label: label ?? this.label,
    locked: locked ?? this.locked,
    enabled: enabled ?? this.enabled,
    transform: transform ?? this.transform,
    effects: effects ?? this.effects,
    outTransition: clearTransition ? null : (outTransition ?? this.outTransition),
  );

  @override
  TextClip copyWithBase({
    Duration? start,
    Duration? duration,
    String? trackId,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => copyWith(
    start: start,
    duration: duration,
    trackId: trackId,
    label: label,
    locked: locked,
    enabled: enabled,
    transform: transform,
    effects: effects,
    outTransition: outTransition,
    clearTransition: clearTransition,
  );

  @override
  Map<String, dynamic> toJson() => {
    ...baseJson(),
    'text': text,
    'style': style.toJson(),
    if (animationIn != TextAnimation.none) 'animIn': animationIn.id,
    if (animationOut != TextAnimation.none) 'animOut': animationOut.id,
    'animUs': animationDuration.inMicroseconds,
    if (isSubtitle) 'subtitle': true,
  };

  factory TextClip.fromJson(Map<String, dynamic> json) => TextClip(
    id: json['id'] as String,
    trackId: json['trackId'] as String,
    start: Duration(microseconds: (json['startUs'] as num?)?.toInt() ?? 0),
    duration: Duration(microseconds: (json['durUs'] as num?)?.toInt() ?? 0),
    text: json['text'] as String? ?? '',
    style: TextStyleSpec.fromJson((json['style'] as Map?)?.cast<String, dynamic>()),
    animationIn: TextAnimation.fromId(json['animIn'] as String?),
    animationOut: TextAnimation.fromId(json['animOut'] as String?),
    animationDuration: Duration(
      microseconds: (json['animUs'] as num?)?.toInt() ?? 600000,
    ),
    isSubtitle: json['subtitle'] as bool? ?? false,
    label: json['label'] as String?,
    locked: json['locked'] as bool? ?? false,
    enabled: !(json['off'] as bool? ?? false),
    transform: Transform2D.fromJson(
      (json['transform'] as Map?)?.cast<String, dynamic>(),
    ),
    effects: _effectsFromJson(json),
    outTransition: _transitionFromJson(json),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Sticker
// ─────────────────────────────────────────────────────────────────────────

final class StickerClip extends Clip {
  const StickerClip({
    required super.id,
    required super.trackId,
    required super.start,
    required super.duration,
    this.stickerId = '',
    this.assetPath,
    this.emoji,
    this.isAnimated = false,
    super.label,
    super.locked,
    super.enabled,
    super.transform,
    super.effects,
    super.outTransition,
  });

  /// Catalogue id for a bundled sticker.
  final String stickerId;

  /// Path for a user-imported sticker (PNG/WebP with alpha).
  final String? assetPath;

  /// When set, the sticker is a rendered emoji glyph rather than an image.
  final String? emoji;

  /// True for animated WebP/GIF stickers, which the compositor must advance.
  final bool isAnimated;

  bool get isEmoji => emoji != null && emoji!.isNotEmpty;

  @override
  ClipKind get kind => ClipKind.sticker;

  StickerClip copyWith({
    String? id,
    String? trackId,
    Duration? start,
    Duration? duration,
    String? stickerId,
    String? assetPath,
    String? emoji,
    bool? isAnimated,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => StickerClip(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    stickerId: stickerId ?? this.stickerId,
    assetPath: assetPath ?? this.assetPath,
    emoji: emoji ?? this.emoji,
    isAnimated: isAnimated ?? this.isAnimated,
    label: label ?? this.label,
    locked: locked ?? this.locked,
    enabled: enabled ?? this.enabled,
    transform: transform ?? this.transform,
    effects: effects ?? this.effects,
    outTransition: clearTransition ? null : (outTransition ?? this.outTransition),
  );

  @override
  StickerClip copyWithBase({
    Duration? start,
    Duration? duration,
    String? trackId,
    String? label,
    bool? locked,
    bool? enabled,
    Transform2D? transform,
    List<Effect>? effects,
    Transition? outTransition,
    bool clearTransition = false,
  }) => copyWith(
    start: start,
    duration: duration,
    trackId: trackId,
    label: label,
    locked: locked,
    enabled: enabled,
    transform: transform,
    effects: effects,
    outTransition: outTransition,
    clearTransition: clearTransition,
  );

  @override
  Map<String, dynamic> toJson() => {
    ...baseJson(),
    if (stickerId.isNotEmpty) 'stickerId': stickerId,
    if (assetPath != null) 'path': assetPath,
    if (emoji != null) 'emoji': emoji,
    if (isAnimated) 'animated': true,
  };

  factory StickerClip.fromJson(Map<String, dynamic> json) => StickerClip(
    id: json['id'] as String,
    trackId: json['trackId'] as String,
    start: Duration(microseconds: (json['startUs'] as num?)?.toInt() ?? 0),
    duration: Duration(microseconds: (json['durUs'] as num?)?.toInt() ?? 0),
    stickerId: json['stickerId'] as String? ?? '',
    assetPath: json['path'] as String?,
    emoji: json['emoji'] as String?,
    isAnimated: json['animated'] as bool? ?? false,
    label: json['label'] as String?,
    locked: json['locked'] as bool? ?? false,
    enabled: !(json['off'] as bool? ?? false),
    transform: Transform2D.fromJson(
      (json['transform'] as Map?)?.cast<String, dynamic>(),
    ),
    effects: _effectsFromJson(json),
    outTransition: _transitionFromJson(json),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────

List<Effect> _effectsFromJson(Map<String, dynamic> json) =>
    ((json['effects'] as List?) ?? const [])
        .map((e) => Effect.fromJson((e as Map).cast<String, dynamic>()))
        .toList();

Transition? _transitionFromJson(Map<String, dynamic> json) {
  final raw = json['outTransition'] as Map?;
  return raw == null ? null : Transition.fromJson(raw.cast<String, dynamic>());
}

/// Linear fade-in/out gain envelope, shared by video and audio clips.
double _fadeGain(
  Duration local,
  Duration total,
  Duration fadeIn,
  Duration fadeOut,
) {
  var gain = 1.0;
  if (fadeIn > Duration.zero && local < fadeIn) {
    gain *= (local.inMicroseconds / fadeIn.inMicroseconds).clamp(0.0, 1.0);
  }
  if (fadeOut > Duration.zero) {
    final remaining = total - local;
    if (remaining < fadeOut) {
      gain *= (remaining.inMicroseconds / fadeOut.inMicroseconds).clamp(0.0, 1.0);
    }
  }
  return gain;
}
