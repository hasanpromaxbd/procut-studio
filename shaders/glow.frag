#version 460 core
#include <flutter/runtime_effect.glsl>

// Bloom: isolate pixels above a luminance threshold, blur them, screen-blend
// back over the original.

uniform vec2 uSize;
uniform float uAmount;
uniform float uThreshold;
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

float luminance(vec3 c) {
    // Rec. 709 coefficients — matches how the encoder computes luma, so the
    // preview thresholds the same pixels the export does.
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec2 texel = 1.0 / uSize;
    vec4 original = texture(uTexture, uv);

    vec3 bloom = vec3(0.0);
    float total = 0.0;
    float radius = 2.0 + uAmount * 10.0;

    for (int x = -3; x <= 3; x++) {
        for (int y = -3; y <= 3; y++) {
            vec2 offset = vec2(float(x), float(y)) * radius * texel;
            vec3 sampled = texture(uTexture, uv + offset).rgb;
            float excess = max(luminance(sampled) - uThreshold, 0.0);
            float weight = 1.0 / (1.0 + float(x * x + y * y));
            bloom += sampled * excess * weight;
            total += weight;
        }
    }
    bloom /= max(total, 0.001);

    // Screen blend: 1 - (1-a)(1-b). Brightens without clipping to white.
    vec3 glowed = 1.0 - (1.0 - original.rgb) * (1.0 - bloom * uAmount * 2.0);
    fragColor = vec4(mix(original.rgb, clamp(glowed, 0.0, 1.0), uIntensity), original.a);
}
