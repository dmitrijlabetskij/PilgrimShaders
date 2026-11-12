#ifndef LIB_FINAL_PASS_GLSL
#define LIB_FINAL_PASS_GLSL

#include "/lib/settings.glsl"
#include "/lib/tonemap.glsl"

#if defined(VERTEX_SHADER)

void main() {
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}

#elif defined(FRAGMENT_SHADER)

uniform sampler2D colortex0;

layout(location = 0) out vec4 outColor;

void main() {
    // Pure single-fetch tonemapper: 0 bilinear overhead, 0 extra G-buffer reads
    vec3 hdrColor = texelFetch(colortex0, ivec2(gl_FragCoord.xy), 0).rgb;
    vec3 finalSrgb = applyGradingAndTonemap(hdrColor, gl_FragCoord.xy);
    outColor = vec4(finalSrgb, 1.0);
}

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_FINAL_PASS_GLSL
