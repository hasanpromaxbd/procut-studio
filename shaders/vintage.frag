#version 460 core
#include <flutter/runtime_effect.glsl>

// Faded print: warm shadows, rolled-off highlights, reduced saturation and a
// vignette. Curves match the `curves` filter used on the export path.

uniform vec2 uSize;
uniform float uAmount;
uniform float uVignette;
uniform float uIntensity;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 original = texture(uTexture, uv);
    vec3 c = original.rgb;

    // Lift blacks per channel — blue lifts most, which is what gives an aged
    // print its characteristic milky, slightly cyan shadow.
    vec3 lift = vec3(0.06, 0.04, 0.10) * uAmount;
    vec3 gain = vec3(0.95, 0.92, 0.88);
    c = lift + c * (gain + (1.0 - gain) * (1.0 - uAmount));

    // Desaturate.
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = mix(c, vec3(luma), 0.35 * uAmount);

    // Warm the midtones.
    c.r += 0.04 * uAmount;
    c.b -= 0.03 * uAmount;

    // Vignette.
    vec2 centred = uv - 0.5;
    float falloff = 1.0 - dot(centred, centred) * 1.6 * uVignette;
    c *= clamp(falloff, 0.0, 1.0);

    fragColor = vec4(mix(original.rgb, clamp(c, 0.0, 1.0), uIntensity), original.a);
}
