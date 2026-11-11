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

    // Single mat4*vec4 + single mat3*vec3 instead of 4 mat4*vec4 transforms
    vec4 unbiasedClip = shadowVP * vec4(feetPos, 1.0);
    float radialDist = length(unbiasedClip.xy);
    if (radialDist >= 0.995) {
        return 1.0;
    }

    float distortFactor = getShadowDistortFactor(unbiasedClip.xy);
    float texelWorldSize = (2.0 * shadowDist / shadowRes) * distortFactor;

    // Normal-offset bias proportional to local distorted texel size
    float biasScale = isFoliage ? 0.55 : (1.15 + 1.10 * (1.0 - max(NdotL, 0.0)));
    vec3 normalClipDelta = mat3(shadowVP) * (worldNormal * (texelWorldSize * biasScale));
    vec4 shadowClip = vec4(unbiasedClip.xyz + normalClipDelta, unbiasedClip.w);
    shadowClip = distortShadowClip(shadowClip);

    vec3 shadowUV = shadowClip.xyz * 0.5 + 0.5;
    if (shadowUV.z <= 0.0 || shadowUV.z >= 1.0) {
        return 1.0;
    }

    // Tiny receiver Z bias to eliminate grazing acne
    shadowUV.z -= 0.00035 * distortFactor;

    float visibility = 0.0;
#if SHADOW_SAMPLES == 1
    // 1 hardware 2x2 PCF tap with slight IGN sub-texel jitter
    float j = (ign(fragCoord) - 0.5) * (0.75 / shadowRes);
    visibility = texture(shadowTex, vec3(shadowUV.xy + vec2(j, -j), shadowUV.z));
#else
    float angle = ign(fragCoord) * TAU;
    float s = sin(angle);
    float c = cos(angle);
    mat2 rot = mat2(c, -s, s, c);
    float radius = 1.25 / shadowRes;

  #if SHADOW_SAMPLES == 2
    const vec2 offsets[2] = vec2[2](vec2(0.85, 0.35), vec2(-0.85, -0.35));
    for (int i = 0; i < 2; i++) {
        visibility += texture(shadowTex, vec3(shadowUV.xy + (rot * offsets[i]) * radius, shadowUV.z));
    }
    visibility *= 0.5;
  #else
    const vec2 offsets[4] = vec2[4](
        vec2( 0.85,  0.35),
        vec2(-0.35,  0.85),
        vec2(-0.85, -0.35),
        vec2( 0.35, -0.85)
    );
    for (int i = 0; i < 4; i++) {
        visibility += texture(shadowTex, vec3(shadowUV.xy + (rot * offsets[i]) * (radius * 1.15), shadowUV.z));
    }
    visibility *= 0.25;
  #endif
#endif

    // Smooth fade out at shadowDistance border
    float edgeFade = smoothstep(0.84, 0.995, radialDist);
    return mix(visibility, 1.0, edgeFade);
}

#endif // LIB_SHADOWS_GLSL
