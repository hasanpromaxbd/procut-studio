#version 460 core
#include <flutter/runtime_effect.glsl>

// Composite-video artefacts: horizontal tearing, chroma bleed, scanlines and
// a rolling tracking band.

uniform vec2 uSize;
uniform float uAmount;
uniform float uScanlines;
uniform float uTime;      // seconds — drives the moving artefacts
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

float hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;

    // Per-scanline horizontal jitter, quantised so it tears in bands rather
    // than smoothly wobbling.
    float line = floor(uv.y * uSize.y / 3.0);
    float jitter = (hash(line + floor(uTime * 12.0)) - 0.5) * 0.02 * uAmount;

    // Slow vertical tracking band, the classic head-switching noise.
    float band = smoothstep(0.0, 0.08, abs(fract(uv.y + uTime * 0.08) - 0.5));
    jitter *= mix(3.0, 1.0, band);

    vec2 shifted = vec2(uv.x + jitter, uv.y);

    // Chroma bleeds to the right of luma on composite video.
    float bleed = 0.004 * uAmount;
    float r = texture(uTexture, shifted + vec2(bleed, 0.0)).r;
    float g = texture(uTexture, shifted).g;
    float b = texture(uTexture, shifted - vec2(bleed * 0.6, 0.0)).b;
    vec3 colour = vec3(r, g, b);

    // Scanlines.
    float scan = 1.0 - uScanlines * 0.35 * (0.5 + 0.5 * sin(uv.y * uSize.y * 3.14159));
    colour *= scan;

    // Tape noise.
    colour += (hash(uv.x * 1234.0 + uv.y * 5678.0 + uTime * 60.0) - 0.5) * 0.08 * uAmount;

    // Slight desaturation and lifted blacks.
    float luma = dot(colour, vec3(0.2126, 0.7152, 0.0722));
    colour = mix(colour, vec3(luma), 0.12 * uAmount);
    colour = colour * 0.94 + 0.03 * uAmount;

    vec4 original = texture(uTexture, uv);
    fragColor = vec4(mix(original.rgb, clamp(colour, 0.0, 1.0), uIntensity), original.a);
}
