#ifndef LIB_MATH_GLSL
#define LIB_MATH_GLSL

// =============================================================================
// Fast Mathematical Primitives (Zero Texture Reads, GLSL 330 & Vulkan 450)
// =============================================================================

const float PI     = 3.14159265359;
const float TAU    = 6.28318530718;
const float INV_PI = 0.31830988618;

float sq(float x) { return x * x; }
vec2  sq(vec2  x) { return x * x; }
vec3  sq(vec3  x) { return x * x; }

float clamp01(float x) { return clamp(x, 0.0, 1.0); }
vec2  clamp01(vec2  x) { return clamp(x, 0.0, 1.0); }
vec3  clamp01(vec3  x) { return clamp(x, 0.0, 1.0); }

float luminance(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 safeNormalize(vec3 v, vec3 fallback) {
    float lenSq = dot(v, v);
    return (lenSq > 1e-8) ? (v * inversesqrt(lenSq)) : fallback;
}

// Fast polynomial sRGB -> Linear (Chilliant, <0.1% error, 0 pow() calls)
vec3 srgbToLinear(vec3 c) {
    c = clamp01(c);
    return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}

// Accurate piecewise Linear -> sRGB for final swapchain output
vec3 linearToSrgb(vec3 c) {
    c = max(c, vec3(0.0));
    vec3 low  = c * 12.92;
    vec3 high = 1.055 * pow(max(c, vec3(1e-5)), vec3(1.0 / 2.4)) - 0.055;
    return mix(low, high, step(vec3(0.0031308), c));
}

// Interleaved Gradient Noise (Jorge Jimenez, 2014) - 0 texture reads
float ign(vec2 fragCoord) {
    return fract(52.9829189 * fract(dot(fragCoord, vec2(0.06711056, 0.00583715))));
}

// Triangular-like centered dither in [-0.5, 0.5]
float ignCentered(vec2 fragCoord) {
    return ign(fragCoord) - 0.5;
}

// Remap Minecraft lightmap coordinates [1/32, 31/32] -> exact [0.0, 1.0]
vec2 remapLightmap(vec2 lmCoord) {
    return clamp01((lmCoord - 0.03125) * (16.0 / 15.0));
}

// Schlick Fresnel approximation
float fresnelSchlick(float cosTheta, float f0) {
    float m = clamp01(1.0 - cosTheta);
    float m2 = m * m;
    return f0 + (1.0 - f0) * (m2 * m2 * m);
}

#endif // LIB_MATH_GLSL
