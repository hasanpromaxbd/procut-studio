#version 460 core
#include <flutter/runtime_effect.glsl>

// Directional blur — a linear smear along uAngle.
//
// The export path uses FFmpeg's `tmix`, which averages real neighbouring
// frames. The preview only has the current frame, so it approximates with a
// spatial smear. The two do not match exactly and the inspector says so.

uniform vec2 uSize;
uniform float uAmount;
uniform float uAngle;
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

const int kSamples = 12;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 original = texture(uTexture, uv);

    if (uAmount < 0.01) {
        fragColor = original;
        return;
    }

    float radians = uAngle * 0.017453292;
    vec2 direction = vec2(cos(radians), sin(radians)) * uAmount * 0.05;

    vec4 sum = vec4(0.0);
    for (int i = 0; i < kSamples; i++) {
        float t = float(i) / float(kSamples - 1) - 0.5;
        sum += texture(uTexture, uv + direction * t);
    }
    sum /= float(kSamples);

    fragColor = mix(original, sum, uIntensity);
}
