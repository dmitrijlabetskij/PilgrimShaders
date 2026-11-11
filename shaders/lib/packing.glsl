#ifndef LIB_PACKING_GLSL
#define LIB_PACKING_GLSL

#include "/lib/math.glsl"

// =============================================================================
// Ultra-Compact G-Buffer Packing (32-bit colortex1 RGBA8)
//   .rg : World-space Octahedral Normal (bit-exact for all 6 cube faces)
//   .b  : Sky Light (8-bit unorm)
//   .a  : Perceptual Block Light (5-bit, 32 levels + IGN dither) | MatID (3-bit)
// =============================================================================

vec2 octEncode(vec3 n) {
    float l1 = abs(n.x) + abs(n.y) + abs(n.z);
    n /= max(l1, 1e-6);
    if (n.z < 0.0) {
        vec2 s = vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
        n.xy = (1.0 - abs(n.yx)) * s;
    }
    // Map [-1, 1] -> [0, 254/255] so 0.0 lands on exact integer 127/255.
    return (n.xy * 0.5 + 0.5) * (254.0 / 255.0);
}

vec3 octDecode(vec2 enc) {
    vec2 e = clamp01(enc * (255.0 / 254.0)) * 2.0 - 1.0;
    vec3 n = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
    if (n.z < 0.0) {
        vec2 s = vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
        n.xy = (1.0 - abs(n.yx)) * s;
    }
    return normalize(n);
}

float packBlockLightAndMat(float blockLight, int matId, float dither01) {
    float blPerceptual = sqrt(clamp01(blockLight));
    float blQuant = clamp(floor(blPerceptual * 31.0 + dither01), 0.0, 31.0);
    float packedByte = blQuant * 8.0 + float(clamp(matId, 0, 7));
    return packedByte / 255.0;
}

void unpackBlockLightAndMat(float packedAlpha, out float blockLight, out int matId) {
    int packedInt = int(round(clamp01(packedAlpha) * 255.0));
    matId = packedInt & 7;
    float blPerceptual = float(packedInt >> 3) / 31.0;
    blockLight = blPerceptual * blPerceptual;
}

vec4 packGbufferData(vec3 worldNormal, float skyLight, float blockLight, int matId, vec2 fragCoord) {
    return vec4(
        octEncode(worldNormal),
        clamp01(skyLight),
        packBlockLightAndMat(blockLight, matId, ign(fragCoord))
    );
}

void unpackGbufferData(vec4 gbuf1, out vec3 worldNormal, out float skyLight, out float blockLight, out int matId) {
    worldNormal = octDecode(gbuf1.rg);
    skyLight = clamp01(gbuf1.b);
    unpackBlockLightAndMat(gbuf1.a, blockLight, matId);
}

#endif // LIB_PACKING_GLSL
