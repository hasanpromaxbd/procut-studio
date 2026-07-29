#version 460 core
#include <flutter/runtime_effect.glsl>

// Zoom, spin and pinch. uMode: 0 = zoom, 1 = spin, 2 = warp.

uniform vec2 uSize;
uniform float uProgress;
uniform float uMode;
uniform float uStrength;
uniform sampler2D uFrom;
uniform sampler2D uTo;

out vec4 fragColor;

vec2 aroundCentre(vec2 uv, float scale, float angleRadians) {
    vec2 c = uv - 0.5;
    float s = sin(angleRadians);
    float co = cos(angleRadians);
    c = vec2(c.x * co - c.y * s, c.x * s + c.y * co);
    return c / max(scale, 0.001) + 0.5;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    float p = clamp(uProgress, 0.0, 1.0);

    // Peaks mid-transition so the distortion opens and closes.
    float envelope = sin(p * 3.14159265);

    float angleFrom = 0.0;
    float angleTo = 0.0;
    float scaleFrom = 1.0;
    float scaleTo = 1.0;

    if (uMode < 0.5) {
        scaleFrom = 1.0 + p * uStrength * 1.5;
        scaleTo = 1.0 - (1.0 - p) * uStrength * 0.6;
    } else if (uMode < 1.5) {
        angleFrom = p * uStrength * 6.2831853;
        angleTo = (p - 1.0) * uStrength * 6.2831853;
        scaleFrom = 1.0 + p * 0.4;
        scaleTo = 1.0 - (1.0 - p) * 0.4;
    } else {
        scaleFrom = 1.0 + envelope * uStrength;
        scaleTo = 1.0 + envelope * uStrength * 0.5;
    }

    vec4 a = texture(uFrom, aroundCentre(uv, scaleFrom, angleFrom));
    vec4 b = texture(uTo, aroundCentre(uv, scaleTo, angleTo));
    fragColor = mix(a, b, smoothstep(0.0, 1.0, p));
}
