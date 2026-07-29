#version 460 core
#include <flutter/runtime_effect.glsl>

// Single-pass approximated Gaussian.
//
// A true separable Gaussian needs two passes and an intermediate target. At
// preview resolution a two-ring 12-tap kernel is visually indistinguishable and
// costs one pass, which is what keeps this inside the 16ms frame budget on a
// mid-range phone.
//
// Offsets are computed with sin/cos in the loop rather than read from a const
// array: SkSL rejects array initializers, and Skia is still the fallback
// backend on devices without a usable Vulkan driver. Twelve sincos pairs per
// fragment is far cheaper than losing the effect entirely on those devices.

uniform vec2 uSize;
uniform float uRadius;    // pixels
uniform float uIntensity; // 0..1 wet/dry
uniform sampler2D uTexture;

out vec4 fragColor;

const int kTaps = 12;
const float kTwoPi = 6.28318530718;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 original = texture(uTexture, uv);

    if (uRadius < 0.5 || uIntensity < 0.01) {
        fragColor = original;
        return;
    }

    vec2 texel = 1.0 / uSize;
    vec4 sum = original * 2.0;
    float weight = 2.0;

    // Two concentric rings approximate the Gaussian falloff: the inner ring
    // carries most of the energy, the outer one softens the tail.
    for (int i = 0; i < kTaps; i++) {
        float angle = kTwoPi * float(i) / float(kTaps);
        vec2 dir = vec2(cos(angle), sin(angle));

        vec2 inner = dir * uRadius * 0.5 * texel;
        vec2 outer = dir * uRadius * texel;

        sum += texture(uTexture, uv + inner) * 1.0;
        sum += texture(uTexture, uv + outer) * 0.5;
        weight += 1.5;
    }

    fragColor = mix(original, sum / weight, uIntensity);
}
