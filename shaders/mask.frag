#version 460 core
#include <flutter/runtime_effect.glsl>

// Shape mask with a feathered edge.
//
// Kept as one shader with a mode switch rather than three: the branch is
// uniform across the whole draw, so every fragment takes the same path and the
// GPU does not diverge. Three shaders would mean three programs to load and
// three uniform layouts to keep in step with the FFmpeg side.
//
// The distance metric is normalised so `d = 1` is always the mask edge,
// whatever the shape — which is what lets one feather calculation serve all of
// them, and what makes this match the `geq` expression used on export.

uniform vec2 uSize;
uniform float uShape;     // 1 = rectangle, 2 = ellipse, 3 = linear
uniform float uCenterX;
uniform float uCenterY;
uniform float uWidth;     // half-extent, fraction of canvas
uniform float uHeight;
uniform float uRotation;  // degrees
uniform float uFeather;   // fraction of canvas
uniform float uInverted;  // 0 or 1
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 original = texture(uTexture, uv);

    if (uShape < 0.5) {
        fragColor = original;
        return;
    }

    // Work in canvas-normalised space, then correct for aspect so a circle is
    // round rather than an ellipse on a 9:16 canvas.
    float aspect = uSize.x / uSize.y;
    vec2 d = vec2((uv.x - uCenterX) * aspect, uv.y - uCenterY);

    float r = radians(uRotation);
    vec2 rot = vec2(
        d.x * cos(r) + d.y * sin(r),
        -d.x * sin(r) + d.y * cos(r)
    );

    vec2 extent = vec2(max(uWidth * aspect, 1e-4), max(uHeight, 1e-4));

    float dist;
    if (uShape < 1.5) {
        // Rectangle: Chebyshev distance in normalised half-extents.
        vec2 q = abs(rot) / extent;
        dist = max(q.x, q.y);
    } else if (uShape < 2.5) {
        // Ellipse: Euclidean distance in the same space.
        vec2 q = rot / extent;
        dist = length(q);
    } else {
        // Linear: a signed half-plane, so the gradient runs one way only.
        dist = rot.y / extent.y * 0.5 + 0.5;
    }

    // Feather is expressed in canvas units; convert to the same normalised
    // scale as `dist` so the softness is visually constant across shapes.
    float feather = max(uFeather / max(uHeight, 1e-4), 1e-4);
    float alpha = 1.0 - smoothstep(1.0 - feather, 1.0 + feather, dist);

    if (uInverted > 0.5) alpha = 1.0 - alpha;

    fragColor = original * clamp(alpha, 0.0, 1.0);
}
