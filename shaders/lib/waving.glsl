#ifndef LIB_WAVING_GLSL
#define LIB_WAVING_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/noise.glsl"

// =============================================================================
// Pure-ALU Wind Animation (Zero Noise Texture Reads)
// Shared identically between gbuffers_terrain, gbuffers_water, and shadow pass
// so leaves/grass shadows match moving geometry in lockstep.
//
// Spatial frequencies are integer multiples of (TAU / 64.0) so wrapping
// cameraPosition modulo 64 blocks causes zero seam and keeps float precision
// crisp even millions of blocks from spawn.
// =============================================================================

vec3 calcWavingOffset(
    vec3 worldPosMod64,
    int blockId,
    float isTopVertex,
    float timeSec,
    float rainStrength
) {
#ifndef WAVE_ANIMATION
    return vec3(0.0);
#else
    const float K = TAU / 64.0;
    float windSpeed = 1.6 + rainStrength * 1.4;
    float windAmp   = 1.0 + rainStrength * 0.65;

    if (blockId == BLOCK_FOLIAGE_GROUND) {
        if (isTopVertex <= 0.0) {
            return vec3(0.0);
        }
        float phase = dot(worldPosMod64, vec3(10.0 * K, 4.0 * K, 8.0 * K)) + timeSec * windSpeed;
        float gust  = sin(dot(worldPosMod64.xz, vec2(3.0 * K, 2.0 * K)) + timeSec * 0.9);
        float sway  = (sin(phase) * 0.65 + cos(phase * 1.7 + 1.1) * 0.35) * (0.075 + 0.035 * gust);
        return vec3(sway * windAmp, 0.0, sway * 0.6 * windAmp) * isTopVertex;
    }

    if (blockId == BLOCK_FOLIAGE_CANOPY) {
        float phaseA = dot(worldPosMod64, vec3(12.0 * K, 14.0 * K, 10.0 * K)) + timeSec * (windSpeed * 0.9);
        float phaseB = dot(worldPosMod64, vec3(7.0 * K, 11.0 * K, 13.0 * K)) + timeSec * (windSpeed * 1.35);
        vec3 offset = vec3(
            sin(phaseA) * 0.042,
            cos(phaseB) * 0.022,
            sin(phaseB + 1.3) * 0.036
        );
        return offset * windAmp;
    }

    if (blockId == BLOCK_WATER) {
        // Very subtle, wide, flat local swells (16x16 grid, ~8.3s lifetime, ~1.8 cm lift)
        vec3 riseA = evalDirectionalWaveletGrid(worldPosMod64.xz, 0.0625, 3, timeSec, 0.12, rainStrength, vec2(0.0), 0, 0.0);
        vec3 riseB = evalDirectionalWaveletGrid(worldPosMod64.xz, 0.0625, 3, timeSec, 0.12, rainStrength, vec2(0.5), 193, 0.5);
        float lift = (riseA.x + riseB.x) * (0.018 + 0.012 * rainStrength) - 0.002;
        return vec3(0.0, lift, 0.0);
    }

    return vec3(0.0);
#endif
}

#endif // LIB_WAVING_GLSL
