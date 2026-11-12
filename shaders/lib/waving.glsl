#ifndef LIB_WAVING_GLSL
#define LIB_WAVING_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

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
        float sway  = (sin(phase) * 0.65 + cos(phase * 1.7 + 1.1) * 0.35) * (0.032 + 0.016 * gust);
        return vec3(sway * windAmp, 0.0, sway * 0.6 * windAmp) * isTopVertex;
    }

    if (blockId == BLOCK_FOLIAGE_CANOPY) {
        float phaseA = dot(worldPosMod64, vec3(12.0 * K, 14.0 * K, 10.0 * K)) + timeSec * (windSpeed * 0.9);
        float phaseB = dot(worldPosMod64, vec3(7.0 * K, 11.0 * K, 13.0 * K)) + timeSec * (windSpeed * 1.35);
        vec3 offset = vec3(
            sin(phaseA) * 0.024,
            cos(phaseB) * 0.014,
            sin(phaseB + 1.3) * 0.020
        );
        return offset * windAmp;
    }

    if (blockId == BLOCK_WATER) {
        // Gentle MakeUp-style surface wave motion (periodic over 64 blocks, stays below shore y=1.0)
        float w1 = sin(worldPosMod64.x * (10.0 * K) + worldPosMod64.z * (6.0 * K) + timeSec * 1.65);
        float w2 = cos(worldPosMod64.x * (6.0 * K) - worldPosMod64.z * (12.0 * K) + timeSec * 1.35);
        float amp = 0.018 + 0.012 * rainStrength;
        return vec3(0.0, (w1 + w2) * amp - 0.020, 0.0);
    }

    return vec3(0.0);
#endif
}

#endif // LIB_WAVING_GLSL
