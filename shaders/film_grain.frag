#version 460 core
#include <flutter/runtime_effect.glsl>

// Luminance-weighted grain.
//
// Real film grain is strongest in the midtones and almost absent in blacks;
// applying uniform noise looks like sensor noise, not film. uTime advances the
// pattern each frame so it does not freeze onto the picture.

uniform vec2 uSize;
uniform float uAmount;
uniform float uGrainSize;
uniform float uTime;
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

float noise(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 original = texture(uTexture, uv);

    vec2 grainUv = floor(FlutterFragCoord().xy / max(uGrainSize, 0.5));
    float n = noise(grainUv + vec2(uTime * 37.0, uTime * 71.0)) - 0.5;

    float luma = dot(original.rgb, vec3(0.2126, 0.7152, 0.0722));
    // Peaks at mid-grey, falls to zero at both ends.
    float response = 4.0 * luma * (1.0 - luma);

    vec3 grained = original.rgb + n * uAmount * 0.25 * response;
    fragColor = vec4(clamp(mix(original.rgb, grained, uIntensity), 0.0, 1.0), original.a);
}
