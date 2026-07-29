#version 460 core
#include <flutter/runtime_effect.glsl>

// Baseline shader. Also the fallback when an effect has no GPU implementation:
// sampling straight through keeps the preview correct rather than blank.

uniform vec2 uSize;
uniform float uOpacity;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    fragColor = texture(uTexture, uv) * uOpacity;
}
