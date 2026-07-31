/// Compiles a [LayerFrame] into FFmpeg filters.
///
/// One `geq` does both jobs — rounded alpha and the coloured border ring —
/// because they share the same signed distance to a rounded rectangle. Two
/// filters would compute that distance twice per pixel for no benefit.
///
/// Coordinates are the *layer's own* pixels (`W`/`H` inside geq are the frame
/// being filtered), so this must run while the layer is still at its own size
/// and before it is padded onto the canvas. Applied after padding, the
/// rounding would follow the canvas edges instead of the picture's.
library;

import '../../domain/entities/layer_frame.dart';
import '../ffmpeg/filter_graph.dart';

abstract final class FrameCompiler {
  /// Filters applying [frame] to a layer of [width]×[height] pixels.
  static List<Filter> build(LayerFrame frame, int width, int height) {
    if (!frame.isActive || width <= 0 || height <= 0) return const [];

    final f = FilterGraph.formatDouble;
    final shortEdge = (width < height ? width : height).toDouble();
    final radius = frame.radiusPx(shortEdge);
    final border = frame.borderPx(shortEdge);

    // Signed distance to a rounded rectangle, the standard formulation:
    // push the corner circle centres inward by the radius, measure to the
    // nearest one, subtract the radius. Negative inside, positive outside.
    //
    //   qx = |X - W/2| - (W/2 - r)   how far past the straight edge, X
    //   qy = |Y - H/2| - (H/2 - r)   likewise, Y
    //   d  = hypot(max(qx,0), max(qy,0)) - r
    //
    // The max(...,0) pair is what keeps the straight edges straight: only
    // when *both* are positive is the pixel in a corner quadrant.
    final qx = '(abs(X-${f(width / 2)})-${f(width / 2 - radius)})';
    final qy = '(abs(Y-${f(height / 2)})-${f(height / 2 - radius)})';
    final distance =
        '(hypot(max($qx,0),max($qy,0))-${f(radius)})';

    // One pixel of ramp at the boundary: enough to kill the jaggies, small
    // enough that the corner does not look blurred.
    final alpha = 'clip(255*(0.5-$distance),0,255)';

    if (!frame.hasBorder) {
      return [
        Filter('format', {'pix_fmts': 'yuva420p'}),
        Filter('geq', {
          'lum': 'p(X,Y)',
          'cb': 'p(X,Y)',
          'cr': 'p(X,Y)',
          'a': alpha,
        }),
      ];
    }

    // The border occupies the band from the edge inwards. `inBorder` is 1
    // inside that band, ramping over the same single pixel so the inner edge
    // of the border is as clean as the outer one.
    final inBorder = 'clip(0.5+($distance+${f(border)})/1,0,1)';

    final (y, u, v) = _toYuv(frame.borderColor);
    String mix(String source, double channel) =>
        '($source*(1-$inBorder)+${f(channel)}*$inBorder)';

    return [
      Filter('format', {'pix_fmts': 'yuva420p'}),
      Filter('geq', {
        'lum': mix('p(X,Y)', y),
        'cb': mix('p(X,Y)', u),
        'cr': mix('p(X,Y)', v),
        'a': alpha,
      }),
    ];
  }

  /// BT.601 full-range, which is what `geq` addresses on a yuva420p frame.
  static (double, double, double) _toYuv(int argb) {
    final r = ((argb >> 16) & 0xFF).toDouble();
    final g = ((argb >> 8) & 0xFF).toDouble();
    final b = (argb & 0xFF).toDouble();
    return (
      0.299 * r + 0.587 * g + 0.114 * b,
      -0.168736 * r - 0.331264 * g + 0.5 * b + 128,
      0.5 * r - 0.418688 * g - 0.081312 * b + 128,
    );
  }
}
