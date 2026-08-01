#version 460 core
#include <flutter/runtime_effect.glsl>

// Colour grading preview — the GPU counterpart of GradeCompiler's filters.
//
// Stage for stage and, where it matters, formula for formula: the tone curve
// is the same arithmetic, and the wheel weights are the same fit to
// `colorbalance`'s measured response. White balance is the one approximation —
// FFmpeg walks the Planckian locus, this scales channels — so a hard push
// towards warm reads slightly differently. The export is the authority; the
// preview has to be right about direction, zone and roughly how far.

uniform vec2 uSize;
uniform float uWarmth;
uniform float uTint;
uniform float uContrast;
uniform float uPivot;
uniform float uShadows;
uniform float uHighlights;
uniform float uLiftX;
uniform float uLiftY;
uniform float uGammaX;
uniform float uGammaY;
uniform float uGainX;
uniform float uGainY;
uniform float uVibrance;
uniform float uSaturation;
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

float luma(vec3 c) {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

// GradeCompiler.toneValue, transliterated.
float tone(float x, float contrast, float pivot, float shadows, float highs) {
    float y = x;

    if (abs(contrast) > 0.002) {
        float e = log(0.5) / log(pivot);
        float u = pow(clamp(x, 0.0, 1.0), e);
        float s = u * u * (3.0 - 2.0 * u);
        y += contrast * (pow(s, 1.0 / e) - x);
    }

    float ws = max(0.0, 1.0 - x / 0.6);
    y += shadows * 0.22 * ws * ws;

    float wh = max(0.0, (x - 0.4) / 0.6);
    y += highs * 0.22 * wh * wh;

    return clamp(y, 0.0, 1.0);
}

// A wheel position as per-channel offsets: red at 90°, green at 210°, blue at
// 330°, each channel taking the projection of the position onto its own axis.
vec3 wheel(float x, float y) {
    float radius = min(1.0, length(vec2(x, y)));
    if (radius < 0.002) return vec3(0.0);
    float angle = atan(y, x);
    const float d = 3.14159265 / 180.0;
    return vec3(
        cos(angle - 90.0 * d),
        cos(angle - 210.0 * d),
        cos(angle - 330.0 * d)
    ) * radius * 0.5;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 source = texture(uTexture, uv);
    vec3 c = source.rgb;

    float mix_ = clamp(uIntensity, 0.0, 1.0);

    // ── White balance ───────────────────────────────────────────────────
    float w = clamp(uWarmth, -1.0, 1.0) * mix_;
    c *= vec3(1.0 + w * 0.18, 1.0 + w * 0.02, 1.0 - w * 0.18);

    float t = clamp(uTint, -1.0, 1.0) * mix_;
    c *= vec3(1.0 - t * 0.06, 1.0 + t * 0.12, 1.0 - t * 0.06);
    c = clamp(c, 0.0, 1.0);

    // ── Tone ────────────────────────────────────────────────────────────
    float pivot = clamp(uPivot, 0.15, 0.85);
    c = vec3(
        tone(c.r, uContrast * mix_, pivot, uShadows * mix_, uHighlights * mix_),
        tone(c.g, uContrast * mix_, pivot, uShadows * mix_, uHighlights * mix_),
        tone(c.b, uContrast * mix_, pivot, uShadows * mix_, uHighlights * mix_)
    );

    // ── Three-way wheels ────────────────────────────────────────────────
    // Lightness the way colorbalance means it — the midpoint of the extremes,
    // not a luma weighting. The zones meet at 0.25, which is the filter's
    // choice and looks wrong on paper until you match it against a real render.
    float l = (max(max(c.r, c.g), c.b) + min(min(c.r, c.g), c.b)) * 0.5;
    float zs = clamp((0.25 - l) / 0.15, 0.0, 1.0);
    float zh = clamp((l - 0.25) / 0.15, 0.0, 1.0);
    float zm = clamp(1.0 - zs - zh, 0.0, 1.0);

    vec3 lift = wheel(uLiftX * mix_, uLiftY * mix_);
    vec3 gamma = wheel(uGammaX * mix_, uGammaY * mix_);
    vec3 gain = wheel(uGainX * mix_, uGainY * mix_);
    c = clamp(c + (lift * zs + gamma * zm + gain * zh) * 0.7, 0.0, 1.0);

    // ── Saturation ──────────────────────────────────────────────────────
    float v = clamp(uVibrance, -1.0, 1.0) * mix_;
    if (abs(v) > 0.002) {
        // Vibrance leans on the unsaturated: the further a pixel already is
        // from grey, the less it moves. That is what keeps skin out of it.
        float grey = luma(c);
        float sat = length(c - vec3(grey)) * 0.577;
        c = clamp(mix(vec3(grey), c, 1.0 + v * 0.8 * (1.0 - sat)), 0.0, 1.0);
    }

    float s = 1.0 + (uSaturation - 1.0) * mix_;
    if (abs(s - 1.0) > 0.002) {
        c = clamp(mix(vec3(luma(c)), c, s), 0.0, 1.0);
    }

    fragColor = vec4(c, source.a);
}
