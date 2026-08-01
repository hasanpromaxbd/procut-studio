/// Skin retouching, built out of ordinary FFmpeg filters.
///
/// ## What this is, and is not
///
/// It finds skin by *colour*, not by finding a face. There is no model here
/// and none is downloaded: skin occupies a well-known, narrow region of the
/// Cb/Cr chroma plane across every skin tone, because what varies between
/// tones is mostly luma. Selecting on chroma therefore works on dark and
/// light skin alike, which a brightness-based approach would not.
///
/// The cost of not detecting a face is that a hand, an arm, or a wooden door
/// of roughly the right hue is treated as skin too. In a shot framed on a
/// person that is rarely visible — and the alternative, shipping a face
/// detector, means hundreds of megabytes of weights and a licence.
///
/// ## Why it branches
///
/// Smoothing that keeps eyes and hair sharp cannot be a single filter: the
/// frame has to be combined with a blurred copy of itself through a mask.
/// That is a small graph, not a chain, which is why this uses the
/// [EffectSpec.buildGraph] hook rather than `buildFilters`.
library;

import '../../domain/entities/effect.dart';
import '../ffmpeg/filter_graph.dart';

abstract final class RetouchCompiler {
  /// Chroma bounds of skin, in the 0–255 range FFmpeg's planes use.
  ///
  /// Skin sits above neutral on Cr (red) and below it on Cb (blue). These
  /// bounds are the widely used ones, narrowed slightly at the Cr top so
  /// strongly red objects — lips, a red shirt — are not smoothed along with
  /// the face.
  static const _cbLow = 77.0;
  static const _cbHigh = 130.0;
  static const _crLow = 135.0;
  static const _crHigh = 175.0;

  /// Builds the retouch graph, returning the label carrying the result.
  static String build(
    FilterGraph graph,
    String input,
    ResolvedEffect effect,
  ) {
    final smooth = effect.value('smooth', 0.5).clamp(0.0, 1.0);
    final glow = effect.value('glow', 0.2).clamp(0.0, 1.0);
    final clarity = effect.value('clarity', 0.3).clamp(0.0, 1.0);

    if (smooth < 0.01 && glow < 0.01 && clarity < 0.01) return input;

    // Full chroma resolution before anything reads the chroma planes: at
    // yuv420p the mask would be built from quarter-resolution colour and show
    // blocky edges along the jawline.
    final prepared = graph.newLabel('rtp');
    graph
        .chain(inputs: [input], outputs: [prepared])
        .then(Filter('format', {'pix_fmts': 'yuv444p'}));

    final original = graph.newLabel('rto');
    final toBlur = graph.newLabel('rtb');
    final toMask = graph.newLabel('rtm');
    graph
        .chain(inputs: [prepared], outputs: [original, toBlur, toMask])
        .then(Filter('split')..arg('3'));

    // `bilateral` rather than a plain blur: it smooths flat areas while
    // holding edges, so the skin softens but the eyelash line does not
    // dissolve. The mask then limits even that to skin.
    final softened = graph.newLabel('rts');
    final soften = graph.chain(inputs: [toBlur], outputs: [softened])
      ..then(
        Filter('bilateral', {
          'sigmaS': FilterGraph.formatDouble(4 + smooth * 14),
          'sigmaR': FilterGraph.formatDouble(0.06 + smooth * 0.22),
        }),
      );
    if (glow > 0.01) {
      // A gentle lift of the mids only: the "lit from in front" look, without
      // touching the black point and flattening the whole image.
      // Unquoted on purpose: `escapeValue` sees the spaces and quotes it once.
      // Quoting it here too produces `all='\'0/0 …\''`, which FFmpeg does not
      // parse — the whole graph then fails to build, not just this filter.
      soften.then(
        Filter('curves', {
          'all': '0/0 0.5/${FilterGraph.formatDouble(0.5 + glow * 0.09)} 1/1',
        }),
      );
    }

    final mask = graph.newLabel('rtk');
    graph
        .chain(inputs: [toMask], outputs: [mask])
        .then(
          Filter('geq', {
            'lum': _skinExpression(),
            'cb': 128,
            'cr': 128,
          }),
        )
        // Feathering the mask is what stops a visible outline where the
        // smoothing stops — a hard-edged skin mask reads as a mask.
        .then(Filter('gblur', {'sigma': 8}));

    final merged = graph.newLabel('rtr');
    graph
        .chain(inputs: [original, softened, mask], outputs: [merged])
        .then(Filter('maskedmerge'));

    if (clarity < 0.01) return merged;

    // Sharpening last and globally: eyes, brows and hair keep their detail
    // because the mask excluded them from the smoothing, and a light overall
    // sharpen brings them back up against the softened skin. Restricting it
    // to an "eye region" would need the face detection this deliberately
    // avoids.
    final sharpened = graph.newLabel('rtc');
    graph
        .chain(inputs: [merged], outputs: [sharpened])
        .then(
          Filter('unsharp', {
            'luma_msize_x': 5,
            'luma_msize_y': 5,
            'luma_amount': FilterGraph.formatDouble(clarity * 1.1),
            'chroma_amount': 0,
          }),
        );
    return sharpened;
  }

  /// White where the pixel's chroma is skin, black elsewhere.
  ///
  /// Ramped rather than a hard threshold at each bound, so a pixel just
  /// outside the range fades out of the effect instead of falling off a
  /// cliff — the same reason the mask is blurred afterwards.
  static String _skinExpression() {
    const soft = 12.0;
    final f = FilterGraph.formatDouble;

    String band(String plane, double low, double high) =>
        'clip(min(($plane(X,Y)-${f(low)})/${f(soft)},'
        '(${f(high)}-$plane(X,Y))/${f(soft)}),0,1)';

    // Both channels must agree: either one alone selects far too much.
    return '255*${band('cb', _cbLow, _cbHigh)}*'
        '${band('cr', _crLow, _crHigh)}';
  }
}
