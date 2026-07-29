#version 460 core
#include <flutter/runtime_effect.glsl>

// Applies a 3D LUT stored as a 2D strip (N tiles of N×N), the standard
// "HALD/LUT PNG" layout. uLutSize is the cube edge, typically 33 or 64.
//
// Blending between the two nearest blue slices is what stops a 33-level cube
// from banding in gradients — a real, visible artefact if skipped.

uniform vec2 uSize;
uniform float uLutSize;
uniform float uMix;
uniform sampler2D uTexture;
uniform sampler2D uLut;

out vec4 fragColor;

vec3 sampleLut(vec3 colour) {
    float size = uLutSize;
    float sliceSize = 1.0 / size;
    float slicePixelSize = sliceSize / size;
    float sliceInnerSize = slicePixelSize * (size - 1.0);

    float blue = clamp(colour.b, 0.0, 1.0) * (size - 1.0);
    float sliceLow = floor(blue);
    float sliceHigh = min(sliceLow + 1.0, size - 1.0);
    float blend = blue - sliceLow;

    float xOffset = slicePixelSize * 0.5 + clamp(colour.r, 0.0, 1.0) * sliceInnerSize;
    float y = slicePixelSize * 0.5 + clamp(colour.g, 0.0, 1.0) * sliceInnerSize;

    vec3 low = texture(uLut, vec2(sliceLow * sliceSize + xOffset, y)).rgb;
    vec3 high = texture(uLut, vec2(sliceHigh * sliceSize + xOffset, y)).rgb;
    return mix(low, high, blend);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 original = texture(uTexture, uv);
    vec3 graded = sampleLut(original.rgb);
    fragColor = vec4(mix(original.rgb, graded, clamp(uMix, 0.0, 1.0)), original.a);
}
