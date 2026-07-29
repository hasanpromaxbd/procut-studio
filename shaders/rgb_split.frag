#version 460 core
#include <flutter/runtime_effect.glsl>

// Chromatic aberration: sample R and B at opposite offsets, keep G centred.

uniform vec2 uSize;
uniform float uOffset;   // pixels
uniform float uAngle;    // degrees
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 original = texture(uTexture, uv);

    float radians = uAngle * 0.017453292;
    vec2 shift = vec2(cos(radians), sin(radians)) * uOffset / uSize;

    float r = texture(uTexture, uv + shift).r;
    float g = original.g;
    float b = texture(uTexture, uv - shift).b;

    fragColor = vec4(mix(original.rgb, vec3(r, g, b), uIntensity), original.a);
}
