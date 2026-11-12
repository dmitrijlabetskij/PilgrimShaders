#ifndef LIB_SHADOWS_GLSL
#define LIB_SHADOWS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

// =============================================================================
// Ultra-Lightweight Distorted Shadow Mapping with Blocker-Aware PCSS
// - Radial clip-space distortion concentrates ~70% texels near player
// - shadowtex0 (HW 2x2 PCF) + shadowtex1 (blocker distance -> realistic soft penumbra)
// - Adaptive normal-offset bias scaled by local distorted texel size
// - Hardware 2x2 PCF via sampler2DShadow with IGN-rotated Vogel offsets (up to 8 taps for tall/high casters)
// =============================================================================

float getShadowDistortFactor(vec2 clipXY) {
    return mix(1.0, length(clipXY), SHADOW_DISTORTION);
}

vec4 distortShadowClip(vec4 clipPos) {
    float factor = getShadowDistortFactor(clipPos.xy);
    clipPos.xy /= factor;
    clipPos.z *= 0.5;
    return clipPos;
}

float sampleShadowMap(
    sampler2DShadow shadowTex,
    sampler2D shadowDepthTex,
    vec3 feetPos,
    vec3 worldNormal,
    float NdotL,
    mat4 shadowVP,
    float shadowDist,
    float shadowRes,
    vec2 fragCoord,
    float shadowFade,
    bool isFoliage
) {
    // Early-out on backfacing opaque surfaces and near horizon transitions (0 texture reads!)
    if (shadowFade <= 0.001 || (!isFoliage && NdotL <= 0.0)) {
        return 0.0;
    }

    // Single mat4*vec4 + single mat3*vec3, avoiding redundant length()/sqrt() calls
    vec4 unbiasedClip = shadowVP * vec4(feetPos, 1.0);
    float radialDistSq = dot(unbiasedClip.xy, unbiasedClip.xy);
    if (radialDistSq >= 0.990) {
        return 1.0;
    }

    float radialDist = sqrt(radialDistSq);
    float distortFactor = mix(1.0, radialDist, SHADOW_DISTORTION);
    float texelWorldSize = (2.0 * shadowDist / shadowRes) * distortFactor;

    // Normal-offset bias paired with PCF radius so slopes never self-shadow,
    // without pushing past thin walls or indoor block corners.
    float biasScale = isFoliage ? 1.55 : (1.35 + 1.25 * (1.0 - max(NdotL, 0.0)));
    vec3 normalClipDelta = mat3(shadowVP) * (worldNormal * (texelWorldSize * biasScale));
    vec4 shadowClip = vec4(unbiasedClip.xyz + normalClipDelta, unbiasedClip.w);
    shadowClip.xy /= distortFactor;
    shadowClip.z *= 0.5;

    vec3 shadowUV = shadowClip.xyz * 0.5 + 0.5;
    if (shadowUV.z <= 0.0 || shadowUV.z >= 1.0) {
        return 1.0;
    }

    // Receiver Z bias scaled by distortion factor to eliminate grazing acne
    shadowUV.z -= 0.00095 * distortFactor;

    // Balanced contact penumbra: crisp near ground/feet (~5.5cm), gently widening with caster height (PCSS)
    float worldPenumbra = mix(0.055, 0.12, smoothstep(0.05, 0.70, radialDist));
    float invRes = 1.0 / shadowRes;
    float visibility = 1.0;
    float noise = ign(fragCoord);

#if SHADOW_SAMPLES == 1
    float r1 = clamp(worldPenumbra / max(texelWorldSize, 1e-4) * 0.50, 0.55, 0.95) * invRes;
    vec2 jitter = (vec2(noise, fract(noise * 17.0)) - 0.5) * (2.0 * r1);
    visibility = texture(shadowTex, vec3(shadowUV.xy + jitter, shadowUV.z));
#else
    float angle = noise * TAU;
    float s = sin(angle);
    float c = cos(angle);
    mat2 rot = mat2(c, -s, s, c);

    // Sparse blocker search in shadowtex1 (center + 3 triangle probes on sunlit borders).
    // Early-skips PCF sampling completely on open sunlit terrain.
    float minBlocker = textureLod(shadowDepthTex, shadowUV.xy, 0.0).r;
    if (minBlocker >= shadowUV.z) {
        float wideR = clamp(0.28 / max(texelWorldSize, 1e-4), 2.5, 8.0) * invRes;
        float d1 = textureLod(shadowDepthTex, shadowUV.xy + (rot * vec2( 0.00,  0.42)) * wideR, 0.0).r;
        float d2 = textureLod(shadowDepthTex, shadowUV.xy + (rot * vec2(-0.78, -0.45)) * wideR, 0.0).r;
        float d3 = textureLod(shadowDepthTex, shadowUV.xy + (rot * vec2( 0.78, -0.45)) * wideR, 0.0).r;
        minBlocker = min(min(minBlocker, d1), min(d2, d3));
    }

    if (minBlocker < shadowUV.z) {
        float uvZPerBlock = 0.25 * length(vec3(shadowVP[0][2], shadowVP[1][2], shadowVP[2][2]));
        float casterDist = (shadowUV.z - minBlocker) / max(uvZPerBlock, 1e-5);

        // Keep standing/low objects sharp; widen penumbra cleanly above ~2.5 blocks height up to 0.32 blocks
        float pcssPenumbra = clamp(worldPenumbra + max(casterDist - 2.5, 0.0) * 0.011, worldPenumbra, 0.32);
        float texelRadius = pcssPenumbra / max(texelWorldSize, 1e-4);
        float radialJitter = 0.82 + 0.36 * fract(noise * 13.73);

        visibility = 0.0;
        if (texelRadius > 3.2) {
            // High casters (e.g. flying player): 8-tap Vogel disk softens silhouette without mushiness
            float radius = clamp(texelRadius, 3.2, 8.0) * invRes;
            const vec2 wideOffsets[8] = vec2[8](
                vec2( 0.250000,  0.000000),
                vec2(-0.319000,  0.292000),
                vec2( 0.049000, -0.556000),
                vec2( 0.440000,  0.490000),
                vec2(-0.740000, -0.055000),
                vec2( 0.530000, -0.630000),
                vec2(-0.105000,  0.880000),
                vec2(-0.620000, -0.740000)
            );
            for (int i = 0; i < 8; i++) {
                visibility += texture(shadowTex, vec3(shadowUV.xy + (rot * wideOffsets[i]) * (radius * radialJitter), shadowUV.z));
            }
            visibility *= 0.125;
        } else {
  #if SHADOW_SAMPLES == 2
            const int SHADOW_TAP_COUNT = 2;
            float radius = clamp(texelRadius, 0.90, 2.00) * invRes;
            const vec2 offsets[2] = vec2[2](vec2(0.32, 0.14), vec2(-0.74, -0.32));
  #elif SHADOW_SAMPLES == 3
            const int SHADOW_TAP_COUNT = 3;
            float radius = clamp(texelRadius, 1.15, 3.20) * invRes;
            const vec2 offsets[3] = vec2[3](
                vec2( 0.260000,  0.000000),
                vec2(-0.440000,  0.408000),
                vec2( 0.085000, -0.936000)
            );
  #else
            const int SHADOW_TAP_COUNT = 4;
            float radius = clamp(texelRadius, 1.35, 3.20) * invRes;
            const vec2 offsets[4] = vec2[4](
                vec2( 0.240000,  0.000000),
                vec2(-0.370000,  0.336000),
                vec2( 0.050000, -0.748000),
                vec2( 0.580000,  0.790000)
            );
  #endif
            for (int i = 0; i < SHADOW_TAP_COUNT; i++) {
                visibility += texture(shadowTex, vec3(shadowUV.xy + (rot * offsets[i]) * (radius * radialJitter), shadowUV.z));
            }
            visibility *= (1.0 / float(SHADOW_TAP_COUNT));
        }
    }
#endif

    // Gentle terminator smoothing on grazing angles and wide fade out at shadowDistance border
    if (!isFoliage) {
        visibility *= smoothstep(0.0, 0.08, NdotL);
    }
    float edgeFade = smoothstep(0.78, 0.995, radialDist);
    return mix(visibility, 1.0, edgeFade);
}

#endif // LIB_SHADOWS_GLSL
