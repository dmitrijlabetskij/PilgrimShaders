#ifndef LIB_SKY_CULL_PASS_GLSL
#define LIB_SKY_CULL_PASS_GLSL

// Vanilla sky, sun/moon textures, and clouds are culled in vertex stage because
// deferred_pass.glsl renders analytical sky, stars, discs, and clouds with 0 textures.

#if defined(VERTEX_SHADER)
void main() {
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
}
#elif defined(FRAGMENT_SHADER)
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor0;
void main() {
    outColor0 = vec4(0.0);
    discard;
}
#endif

#endif // LIB_SKY_CULL_PASS_GLSL
