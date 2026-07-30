/// Voice character presets for audio clips.
///
/// Each preset is a fixed, named chain of ordinary DSP — pitch, band-passes,
/// echo, spectral mangling. They are deliberately *presets*, not parameters:
/// "robot" that needs tuning is a failure of the preset, and anyone who wants
/// surgical control already has pitch and the EQ.
library;

enum VoiceEffect {
  none('None', 'The voice as recorded'),
  deep('Deep', 'Down five semitones — movie-trailer register'),
  helium('Helium', 'Up seven semitones'),
  robot('Robot', 'Phase-flattened — the classic machine voice'),
  telephone('Telephone', 'Band-limited to a phone line'),
  echo('Echo', 'One clean repeat, half a second behind'),
  cave('Cave', 'Long overlapping reflections');

  const VoiceEffect(this.label, this.blurb);

  final String label;
  final String blurb;

  bool get isActive => this != VoiceEffect.none;

  static VoiceEffect fromId(String? id) => VoiceEffect.values.firstWhere(
    (e) => e.name == id,
    orElse: () => VoiceEffect.none,
  );

  /// Semitone shift this preset applies, consumed by the same pitch machinery
  /// as the manual control — the two compose by simple addition.
  double get semitones => switch (this) {
    VoiceEffect.deep => -5,
    VoiceEffect.helium => 7,
    _ => 0,
  };
}
