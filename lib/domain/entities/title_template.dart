/// Ready-made animated titles.
///
/// A template is nothing but a [TextClip] configuration — style, animation,
/// placement and, where the movement is more than the built-in animations
/// express, transform keyframes. Nothing about a placed title is special
/// afterwards: it is an ordinary text clip that can be retyped, restyled,
/// moved, curved or deleted like any other. That is deliberate; a template
/// system that produces un-editable objects is a trap.
library;

import 'keyframe.dart';
import 'text_style_spec.dart';
import 'transform2d.dart';

enum TitleTemplate {
  lowerThird(
    'Lower third',
    'Name and role, bottom left',
    'Your Name',
    Duration(seconds: 4),
  ),
  titleCard(
    'Title card',
    'Big centred title for an opening',
    'TITLE',
    Duration(seconds: 3),
  ),
  quote(
    'Quote',
    'Centred, generous spacing',
    '“The quiet part.”',
    Duration(seconds: 5),
  ),
  subscribeBug(
    'Subscribe bug',
    'Small nudge that slides in and out',
    'Subscribe',
    Duration(seconds: 4),
  ),
  chapterMark(
    'Chapter',
    'Section heading, top left',
    'Chapter one',
    Duration(seconds: 3),
  ),
  bigCaption(
    'Big caption',
    'Heavy centred line for a punchline',
    'Wait for it',
    Duration(seconds: 2),
  );

  const TitleTemplate(
    this.label,
    this.blurb,
    this.placeholder,
    this.defaultDuration,
  );

  final String label;
  final String blurb;

  /// What the title says until the user types over it. Placeholder text, not
  /// an empty clip: an invisible new layer is impossible to find.
  final String placeholder;

  final Duration defaultDuration;

  TextStyleSpec get style => switch (this) {
    TitleTemplate.lowerThird => const TextStyleSpec(
      fontSize: 0.038,
      fontWeight: 700,
      alignment: TextAlignment.left,
      backgroundColor: 0xCC101018,
      backgroundPadding: 0.014,
      backgroundRadius: 0.006,
    ),
    TitleTemplate.titleCard => const TextStyleSpec(
      fontSize: 0.085,
      fontWeight: 800,
      allCaps: true,
      letterSpacing: 0.04,
      strokeWidth: 0.03,
    ),
    TitleTemplate.quote => const TextStyleSpec(
      fontSize: 0.05,
      fontWeight: 400,
      italic: true,
      lineHeight: 1.45,
    ),
    TitleTemplate.subscribeBug => const TextStyleSpec(
      fontSize: 0.032,
      fontWeight: 700,
      allCaps: true,
      backgroundColor: 0xEEE0324B,
      backgroundPadding: 0.013,
      backgroundRadius: 0.02,
    ),
    TitleTemplate.chapterMark => const TextStyleSpec(
      fontSize: 0.042,
      fontWeight: 600,
      alignment: TextAlignment.left,
      strokeWidth: 0.05,
    ),
    TitleTemplate.bigCaption => const TextStyleSpec(
      fontSize: 0.07,
      fontWeight: 800,
      allCaps: true,
      strokeWidth: 0.1,
    ),
  };

  TextAnimation get animationIn => switch (this) {
    TitleTemplate.lowerThird => TextAnimation.slideUp,
    TitleTemplate.titleCard => TextAnimation.popIn,
    TitleTemplate.quote => TextAnimation.fadeIn,
    TitleTemplate.subscribeBug => TextAnimation.slideUp,
    TitleTemplate.chapterMark => TextAnimation.wipe,
    TitleTemplate.bigCaption => TextAnimation.bounce,
  };

  TextAnimation get animationOut => switch (this) {
    TitleTemplate.subscribeBug => TextAnimation.slideDown,
    TitleTemplate.bigCaption => TextAnimation.popIn,
    _ => TextAnimation.fadeIn,
  };

  /// Where the title sits, and any movement the built-in animations do not
  /// cover.
  ///
  /// [duration] is the clip's, because keyframe times are clip-local: a
  /// template placed on a 2-second clip and the same one on a 6-second clip
  /// must both settle at the same *fraction* of the way through, not the same
  /// number of seconds.
  Transform2D transformFor(Duration duration) {
    final settle = Duration(
      microseconds: (duration.inMicroseconds * 0.18).round(),
    );
    final leave = Duration(
      microseconds: (duration.inMicroseconds * 0.86).round(),
    );

    return switch (this) {
      TitleTemplate.lowerThird => Transform2D.identity.copyWith(
        x: const AnimatableDouble(-0.16),
        y: const AnimatableDouble(0.3),
      ),
      TitleTemplate.chapterMark => Transform2D.identity.copyWith(
        x: const AnimatableDouble(-0.18),
        y: const AnimatableDouble(-0.34),
      ),
      TitleTemplate.quote => Transform2D.identity.copyWith(
        y: const AnimatableDouble(-0.02),
      ),
      // The bug slides in from off the right edge, sits, then leaves the same
      // way — the movement is the template, so it is keyframed rather than
      // left to a generic animation.
      TitleTemplate.subscribeBug => Transform2D.identity.copyWith(
        y: const AnimatableDouble(0.32),
        x: AnimatableDouble(
          0.6,
          keyframes: [
            const Keyframe(time: Duration.zero, value: 0.6),
            Keyframe(time: settle, value: 0.3),
            Keyframe(time: leave, value: 0.3),
            Keyframe(time: duration, value: 0.6),
          ],
        ),
      ),
      // A slow push over the whole card: the difference between a title that
      // is placed and one that is designed.
      TitleTemplate.titleCard => Transform2D.identity.copyWith(
        scaleX: AnimatableDouble(
          1,
          keyframes: [
            const Keyframe(time: Duration.zero, value: 1),
            Keyframe(time: duration, value: 1.08),
          ],
        ),
        scaleY: AnimatableDouble(
          1,
          keyframes: [
            const Keyframe(time: Duration.zero, value: 1),
            Keyframe(time: duration, value: 1.08),
          ],
        ),
      ),
      TitleTemplate.bigCaption => Transform2D.identity,
    };
  }
}
