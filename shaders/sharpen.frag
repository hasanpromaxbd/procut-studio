#version 460 core
#include <flutter/runtime_effect.glsl>

// Unsharp mask: original + amount * (original - blurred).

uniform vec2 uSize;
uniform float uAmount;
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec2 texel = 1.0 / uSize;
    vec4 original = texture(uTexture, uv);

    vec4 blurred =
        texture(uTexture, uv + vec2(-texel.x, -texel.y)) * 0.0625 +
        texture(uTexture, uv + vec2( 0.0,     -texel.y)) * 0.125  +
        texture(uTexture, uv + vec2( texel.x, -texel.y)) * 0.0625 +
        texture(uTexture, uv + vec2(-texel.x,  0.0))     * 0.125  +
        original                                          * 0.25   +
        texture(uTexture, uv + vec2( texel.x,  0.0))     * 0.125  +
        texture(uTexture, uv + vec2(-texel.x,  texel.y)) * 0.0625 +
        texture(uTexture, uv + vec2( 0.0,      texel.y)) * 0.125  +
        texture(uTexture, uv + vec2( texel.x,  texel.y)) * 0.0625;

    vec4 sharpened = original + (original - blurred) * uAmount;
    fragColor = vec4(clamp(mix(original, sharpened, uIntensity).rgb, 0.0, 1.0), original.a);
}
