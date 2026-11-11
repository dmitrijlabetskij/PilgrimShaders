#ifndef LIB_IRIS_COMPAT_GLSL
#define LIB_IRIS_COMPAT_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

// =============================================================================
// Iris OpenGL Backend Compatibility Adapter
// Isolates all OpenGL/Iris-specific built-in inputs & matrices from /lib/*.glsl.
// When porting to Iris Aperture / Vulkan, only this adapter + pass wrappers change.
// =============================================================================

#ifndef SHADOW_RES_CONST
  #define SHADOW_RES_CONST 1024
#endif
#ifndef SHADOW_DIST_CONST
  #define SHADOW_DIST_CONST 96.0
#endif

// Reconstruct camera-relative position ("feetPos") from screen UV [0, 1] and depth [0, 1]
vec3 reconstructViewPos(vec2 uv, float depth, mat4 projInverse) {
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 viewPos = projInverse * ndc;
    return viewPos.xyz / viewPos.w;
}

vec3 viewToFeetPos(vec3 viewPos, mat4 modelViewInverse) {
    return (modelViewInverse * vec4(viewPos, 1.0)).xyz;
}

vec3 viewDirToWorld(vec3 dirView, mat4 modelViewInverse) {
    return normalize(mat3(modelViewInverse) * dirView);
}

// Compute camera-relative world position wrapped at 64-block intervals for wave precision
vec3 getWorldPosMod64(vec3 feetPos, vec3 camPos) {
    return feetPos + mod(camPos, 64.0);
}

#endif // LIB_IRIS_COMPAT_GLSL
