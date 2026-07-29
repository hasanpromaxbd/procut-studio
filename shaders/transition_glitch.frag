#version 460 core
#include <flutter/runtime_effect.glsl>

// Digital tear: horizontal bands displace independently, with channel
// separation peaking mid-transition.

uniform vec2 uSize;
uniform float uProgress;
uniform float uStrength;
uniform sampler2D uFrom;
uniform sampler2D uTo;

out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    float p = clamp(uProgress, 0.0, 1.0);
    float envelope = sin(p * 3.14159265);

    // ~24px bands. Quantising means the tear reads as blocks, not noise.
    float band = floor(uv.y * uSize.y / 24.0);
    float seed = hash(vec2(band, floor(p * 20.0)));
    float displace = (seed - 0.5) * uStrength * 0.15 * envelope;

    vec2 torn = vec2(uv.x + displace, uv.y);
    float aberration = uStrength * 0.01 * envelope;

    vec4 a = vec4(
        texture(uFrom, torn + vec2(aberration, 0.0)).r,
        texture(uFrom, torn).g,
        texture(uFrom, torn - vec2(aberration, 0.0)).b,
        texture(uFrom, torn).a
    );
    vec4 b = vec4(
        texture(uTo, torn - vec2(aberration, 0.0)).r,
        texture(uTo, torn).g,
        texture(uTo, torn + vec2(aberration, 0.0)).b,
        texture(uTo, torn).a
    );

    // Bands cross over at slightly different times, which is what sells it as
    // a signal fault rather than a fade.
    float bandThreshold = p * 1.3 - seed * 0.3;
    fragColor = bandThreshold > 0.5 ? b : mix(a, b, smoothstep(0.35, 0.65, p));
}
