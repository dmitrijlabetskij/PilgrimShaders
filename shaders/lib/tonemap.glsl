#ifndef LIB_TONEMAP_GLSL
#define LIB_TONEMAP_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

// =============================================================================
// Fast Filmic Tonemapping (AgX Minimal & ACES Stephen Hill) + Color Grading
// =============================================================================

// Troy Sobotka's AgX Minimal approximation (smooth highlight roll-off, preserves orange/red hues)
vec3 agxDefaultContrastApprox(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return + 15.5     * x4 * x2
           - 40.14    * x4 * x
           + 31.96    * x4
           - 6.868    * x2 * x
           + 0.4298   * x2
           + 0.1191   * x
           - 0.00232;
}

vec3 tonemapAgX(vec3 col) {
    const mat3 agxMat = mat3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772, 0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104
    );
    const mat3 agxOutMat = mat3(
         1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116
    );
    const float minEv = -12.47393;
    const float maxEv = 4.026069;

    col = max(col, vec3(0.0));
    col = agxMat * col;
    col = max(col, vec3(1e-6));
    col = log2(col);
    col = clamp01((col - minEv) / (maxEv - minEv));
    col = agxDefaultContrastApprox(col);
    col = agxOutMat * col;
    // agxOutMat outputs display-encoded (~sRGB 2.2) values; decode back to linear
    return pow(clamp01(col), vec3(2.2));
}

// Stephen Hill ACES RRT+ODT fit
vec3 tonemapACES(vec3 col) {
    const mat3 acesIn = mat3(
        0.59719, 0.07600, 0.02840,
        0.35458, 0.90834, 0.13383,
        0.04823, 0.01566, 0.83777
    );
    const mat3 acesOut = mat3(
         1.60475, -0.10208, -0.00327,
        -0.53108,  1.10813, -0.07276,
        -0.07367, -0.00605,  1.07602
    );
    col = acesIn * max(col, vec3(0.0));
    vec3 a = col * (col + 0.0245786) - 0.000090537;
    vec3 b = col * (0.983729 * col + 0.4329510) + 0.238081;
    return clamp01(acesOut * (a / b));
}

vec3 applyGradingAndTonemap(vec3 hdrColor, vec2 fragCoord) {
    vec3 col = max(hdrColor, vec3(0.0)) * EXPOSURE;

#if TONEMAP_MODE == 0
    col = tonemapAgX(col);
#else
    col = tonemapACES(col);
#endif

    // Saturation in linear space (preserves luminance accurately)
    float luma = luminance(col);
    col = max(mix(vec3(luma), col, SATURATION), vec3(0.0));

    // Linear -> sRGB + non-crushing S-curve contrast + 8-bit IGN dither
    vec3 srgb = linearToSrgb(col);
    float cAmt = (CONTRAST - 1.0) * 1.5;
    vec3 sCurve = srgb * srgb * (3.0 - 2.0 * srgb);
    srgb = clamp01(srgb + (sCurve - srgb) * cAmt);
    srgb += ignCentered(fragCoord) / 255.0;
    return clamp01(srgb);
}

#endif // LIB_TONEMAP_GLSL
