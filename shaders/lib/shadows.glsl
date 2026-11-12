#ifndef LIB_SHADOWS_GLSL
#define LIB_SHADOWS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

// =============================================================================
// Ultra-Lightweight Distorted Shadow Mapping
// - Radial clip-space distortion concentrates ~70% texels near player
// - Only 1 shadow texture (shadowtex0), NO shadowcolor buffers
// - Adaptive normal-offset bias scaled by local distorted texel size
// - Hardware 2x2 PCF via sampler2DShadow with IGN-rotated 1/2/4-tap Vogel offsets
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

    // Normal-offset bias strictly larger than PCF radius so slopes never self-shadow,
    // without pushing past thin walls or indoor block corners.
    float biasScale = isFoliage ? 1.25 : (0.95 + 0.85 * (1.0 - max(NdotL, 0.0)));
    vec3 normalClipDelta = mat3(shadowVP) * (worldNormal * (texelWorldSize * biasScale));
    vec4 shadowClip = vec4(unbiasedClip.xyz + normalClipDelta, unbiasedClip.w);
    shadowClip.xy /= distortFactor;
    shadowClip.z *= 0.5;

    vec3 shadowUV = shadowClip.xyz * 0.5 + 0.5;
    if (shadowUV.z <= 0.0 || shadowUV.z >= 1.0) {
        return 1.0;
    }

    // Receiver Z bias scaled by distortion factor to eliminate grazing acne
    shadowUV.z -= 0.00065 * distortFactor;

    // Compact filter radius paired with hardware 2x2 PCF: crisp shadows without hollow-ring halos
    float radius = mix(0.78, 0.45, distortFactor) / shadowRes;

    float visibility = 0.0;
    float noise = ign(fragCoord);
#if SHADOW_SAMPLES == 1
    vec2 jitter = (vec2(noise, fract(noise * 17.0)) - 0.5) * (0.45 / shadowRes);
    visibility = texture(shadowTex, vec3(shadowUV.xy + jitter, shadowUV.z));
#else
    float angle = noise * TAU;
    float s = sin(angle);
    float c = cos(angle);
    mat2 rot = mat2(c, -s, s, c);

  #if SHADOW_SAMPLES == 2
    // Filled asymmetric 2-tap (center-biased + outer) avoids 2-point gaps
    const vec2 offsets[2] = vec2[2](vec2(0.32, 0.14), vec2(-0.74, -0.32));
    for (int i = 0; i < 2; i++) {
        visibility += texture(shadowTex, vec3(shadowUV.xy + (rot * offsets[i]) * radius, shadowUV.z));
    }
    visibility *= 0.5;
  #elif SHADOW_SAMPLES == 3
    // 3-tap Vogel spiral fills interior -> edge smoothly (12 HW PCF taps, zero hollow rings)
    const vec2 offsets[3] = vec2[3](
        vec2( 0.408248,  0.000000),
        vec2(-0.521300,  0.477460),
        vec2( 0.080160, -0.909350)
    );
    for (int i = 0; i < 3; i++) {
        visibility += texture(shadowTex, vec3(shadowUV.xy + (rot * offsets[i]) * radius, shadowUV.z));
    }
    visibility *= (1.0 / 3.0);
  #else
    // 4-tap Vogel spiral fills interior -> edge smoothly (16 HW PCF taps)
    const vec2 offsets[4] = vec2[4](
        vec2( 0.353553,  0.000000),
        vec2(-0.451400,  0.413500),
        vec2( 0.053700, -0.788800),
        vec2( 0.550600,  0.756200)
    );
    for (int i = 0; i < 4; i++) {
        visibility += texture(shadowTex, vec3(shadowUV.xy + (rot * offsets[i]) * radius, shadowUV.z));
    }
    visibility *= 0.25;
  #endif
#endif

    // Gentle terminator smoothing on grazing angles and fade out at shadowDistance border
    if (!isFoliage) {
        visibility *= smoothstep(0.0, 0.08, NdotL);
    }
    float edgeFade = smoothstep(0.84, 0.995, radialDist);
    return mix(visibility, 1.0, edgeFade);
}

#endif // LIB_SHADOWS_GLSL
