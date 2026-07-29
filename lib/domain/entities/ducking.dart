/// Automatic level ducking — music that steps out of the way of a voice.
///
/// Deliberately modelled per *track*, not per clip: "the music track ducks
/// under the voice track" is the thing an editor means, and it must keep
/// working when clips are split, moved or replaced.
///
/// ## Why there is no "duck by −12 dB"
///
/// Ducking is a side-chain compressor, and a compressor's gain reduction is a
/// function of how far the key signal exceeds the threshold:
///
///   reduction ≈ (1 − 1/ratio) × (key level − threshold)
///
/// A loud narrator therefore ducks the music further than a quiet one, which
/// is the behaviour people actually want. Exposing a fixed dB figure would be
/// a lie about what the filter does, so the two real controls are exposed
/// instead, under names that say what they change.
library;

import 'dart:math' as math;

class Ducking {
  const Ducking({
    required this.keyTrackId,
    this.strength = 4.0,
    this.sensitivity = 0.05,
    this.attack = const Duration(milliseconds: 20),
    this.release = const Duration(milliseconds: 300),
  });

  /// The track whose audio triggers the duck — the voice, normally.
  final String keyTrackId;

  /// Compression ratio. 1 is no ducking at all; 20 is a hard duck.
  final double strength;

  /// Linear threshold (0–1). Lower means quieter speech still triggers it.
  final double sensitivity;

  /// How fast the level drops when the voice starts. Too fast pumps; too slow
  /// lets the first syllable through at full music level.
  final Duration attack;

  /// How fast it comes back once the voice stops. This is the one people get
  /// wrong: a short release makes the music breathe between words.
  final Duration release;

  bool get isActive => strength > 1.01 && keyTrackId.isNotEmpty;

  /// Approximate reduction for a key signal [keyDb] below full scale, so the
  /// UI can say something concrete without pretending it is a fixed setting.
  double reductionDbFor(double keyDb) {
    final thresholdDb = 20 * math.log(sensitivity.clamp(1e-4, 1.0)) / math.ln10;
    final over = keyDb - thresholdDb;
    if (over <= 0) return 0;
    return (1 - 1 / strength) * over;
  }

  Ducking copyWith({
    String? keyTrackId,
    double? strength,
    double? sensitivity,
    Duration? attack,
    Duration? release,
  }) => Ducking(
    keyTrackId: keyTrackId ?? this.keyTrackId,
    strength: strength ?? this.strength,
    sensitivity: sensitivity ?? this.sensitivity,
    attack: attack ?? this.attack,
    release: release ?? this.release,
  );

  Map<String, dynamic> toJson() => {
    'key': keyTrackId,
    'strength': strength,
    'sensitivity': sensitivity,
    'attackMs': attack.inMilliseconds,
    'releaseMs': release.inMilliseconds,
  };

  static Ducking? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final key = json['key'] as String?;
    if (key == null || key.isEmpty) return null;
    return Ducking(
      keyTrackId: key,
      strength: (json['strength'] as num?)?.toDouble() ?? 4.0,
      sensitivity: (json['sensitivity'] as num?)?.toDouble() ?? 0.05,
      attack: Duration(milliseconds: (json['attackMs'] as num?)?.toInt() ?? 20),
      release: Duration(
        milliseconds: (json['releaseMs'] as num?)?.toInt() ?? 300,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Ducking &&
      other.keyTrackId == keyTrackId &&
      other.strength == strength &&
      other.sensitivity == sensitivity &&
      other.attack == attack &&
      other.release == release;

  @override
  int get hashCode =>
      Object.hash(keyTrackId, strength, sensitivity, attack, release);
}
