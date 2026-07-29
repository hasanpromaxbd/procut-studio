#version 460 core
#include <flutter/runtime_effect.glsl>

// Concentric wave expanding from the centre, displacing both frames.

uniform vec2 uSize;
uniform float uProgress;
uniform float uAmplitude;
uniform sampler2D uFrom;
uniform sampler2D uTo;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    float p = clamp(uProgress, 0.0, 1.0);

    vec2 centred = uv - 0.5;
    // Correct for aspect so the wavefront is circular, not elliptical.
    centred.x *= uSize.x / uSize.y;
    float dist = length(centred);

    float envelope = sin(p * 3.14159265);
    float wave = sin(dist * 28.0 - p * 18.0) * uAmplitude * 0.03 * envelope;

    // Displacement falls off with distance so the centre is not over-stretched.
    vec2 offset = normalize(centred + vec2(1e-6)) * wave / (1.0 + dist * 2.0);

    vec4 a = texture(uFrom, uv + offset);
    vec4 b = texture(uTo, uv - offset);
    fragColor = mix(a, b, smoothstep(0.0, 1.0, p));
}
