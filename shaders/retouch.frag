#version 460 core
#include <flutter/runtime_effect.glsl>

// Skin retouch preview — the GPU counterpart of RetouchCompiler's FFmpeg graph.
//
// Same idea, cheaper arithmetic: find skin by chroma, smooth only there with an
// edge-preserving kernel, lift the mids, then sharpen the whole frame so the
// features excluded from the smoothing read as crisper against it.
//
// The export is the authority on the final image; this only has to agree about
// *where* the effect lands and roughly how strong it is, at 60fps.

uniform vec2 uSize;
uniform float uSmooth;
uniform float uGlow;
uniform float uClarity;
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

// BT.601, matching the planes FFmpeg's geq reads.
float luma(vec3 c) {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

// A band with soft shoulders rather than a hard threshold, so a pixel just
// outside the range fades out of the effect instead of falling off a cliff.
float band(float v, float low, float high, float soft) {
    return clamp(min((v - low) / soft, (high - v) / soft), 0.0, 1.0);
}

// White on skin, black elsewhere. Bounds are the compiler's, rescaled to 0–1.
float skin(vec3 c) {
    float y = luma(c);
    float cb = 0.5 + (c.b - y) * 0.564;
    float cr = 0.5 + (c.r - y) * 0.713;
    float soft = 12.0 / 255.0;
    return band(cb, 77.0 / 255.0, 130.0 / 255.0, soft) *
           band(cr, 135.0 / 255.0, 175.0 / 255.0, soft);
}

// One bilateral tap: near in space *and* near in colour, or it does not count.
// That range term is what keeps the eyelash line out of the average.
void tap(
    vec2 uv,
    vec2 off,
    vec3 centre,
    float sigmaR,
    inout vec3 accum,
    inout float weight
) {
    vec3 s = texture(uTexture, uv + off).rgb;
    float d = distance(s, centre);
    float w = exp(-(d * d) / (2.0 * sigmaR * sigmaR));
    accum += s * w;
    weight += w;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec2 texel = 1.0 / uSize;
    vec4 source = texture(uTexture, uv);
    vec3 original = source.rgb;

    float strength = clamp(uIntensity, 0.0, 1.0);
    float mask = skin(original) * strength;

    // Radius grows with the smoothing amount; the range sigma does too, so a
    // stronger setting also crosses slightly larger tonal steps.
    float radius = 1.0 + uSmooth * 2.5;
    float sigmaR = 0.06 + uSmooth * 0.22;

    vec3 accum = original;
    float weight = 1.0;
    vec2 r1 = texel * radius;
    vec2 r2 = texel * radius * 1.8;

    tap(uv, vec2(r1.x, 0.0), original, sigmaR, accum, weight);
    tap(uv, vec2(-r1.x, 0.0), original, sigmaR, accum, weight);
    tap(uv, vec2(0.0, r1.y), original, sigmaR, accum, weight);
    tap(uv, vec2(0.0, -r1.y), original, sigmaR, accum, weight);
    tap(uv, vec2(r1.x, r1.y), original, sigmaR, accum, weight);
    tap(uv, vec2(-r1.x, r1.y), original, sigmaR, accum, weight);
    tap(uv, vec2(r1.x, -r1.y), original, sigmaR, accum, weight);
    tap(uv, vec2(-r1.x, -r1.y), original, sigmaR, accum, weight);
    tap(uv, vec2(r2.x, 0.0), original, sigmaR, accum, weight);
    tap(uv, vec2(-r2.x, 0.0), original, sigmaR, accum, weight);
    tap(uv, vec2(0.0, r2.y), original, sigmaR, accum, weight);
    tap(uv, vec2(0.0, -r2.y), original, sigmaR, accum, weight);

    vec3 softened = accum / weight;

    // The mid-tone lift, on skin only — the same curve the export applies, so
    // a face brightens without the whole shot going milky.
    softened += uGlow * 0.09 * 4.0 * softened * (1.0 - softened);

    vec3 result = mix(original, softened, mask * clamp(uSmooth, 0.0, 1.0));

    if (uClarity > 0.001) {
        vec3 low =
            texture(uTexture, uv + vec2(texel.x, 0.0)).rgb * 0.25 +
            texture(uTexture, uv + vec2(-texel.x, 0.0)).rgb * 0.25 +
            texture(uTexture, uv + vec2(0.0, texel.y)).rgb * 0.25 +
            texture(uTexture, uv + vec2(0.0, -texel.y)).rgb * 0.25;
        result += (original - low) * uClarity * 1.1 * strength;
    }

    fragColor = vec4(clamp(result, 0.0, 1.0), source.a);
}
