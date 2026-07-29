#version 460 core
#include <flutter/runtime_effect.glsl>

// Cross-dissolve, plus the directional wipe/slide variants.
// uMode: 0 = dissolve, 1 = slide, 2 = wipe, 3 = flash-to-white.
// uDirX/uDirY give the direction for the directional modes.

uniform vec2 uSize;
uniform float uProgress;  // 0..1
uniform float uMode;
uniform float uDirX;
uniform float uDirY;
uniform sampler2D uFrom;
uniform sampler2D uTo;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    float p = clamp(uProgress, 0.0, 1.0);
    vec2 dir = vec2(uDirX, uDirY);

    if (uMode < 0.5) {
        fragColor = mix(texture(uFrom, uv), texture(uTo, uv), p);
        return;
    }

    if (uMode < 1.5) {
        // Slide: both frames move together.
        vec2 offset = dir * p;
        vec4 a = texture(uFrom, uv + offset);
        vec4 b = texture(uTo, uv + offset - dir);
        float edge = dot(uv, normalize(dir + vec2(1e-6)));
        float threshold = dot(dir, dir) > 0.0 ? p : p;
        fragColor = edge < threshold ? b : a;
        return;
    }

    if (uMode < 2.5) {
        // Wipe: a hard edge sweeps across, the outgoing frame stays put.
        float coord = dir.x != 0.0
            ? (dir.x > 0.0 ? uv.x : 1.0 - uv.x)
            : (dir.y > 0.0 ? uv.y : 1.0 - uv.y);
        fragColor = coord < p ? texture(uTo, uv) : texture(uFrom, uv);
        return;
    }

    // Flash: out to white at the midpoint, in from white after.
    float flash = 1.0 - abs(p * 2.0 - 1.0);
    vec4 base = mix(texture(uFrom, uv), texture(uTo, uv), step(0.5, p));
    fragColor = vec4(mix(base.rgb, vec3(1.0), flash), base.a);
}
