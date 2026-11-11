#ifndef LIB_WATER_GLSL
#define LIB_WATER_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/noise.glsl"
#include "/lib/atmosphere.glsl"

// =============================================================================
// Ultra-Fast Forward Water Shader (0 normal-map reads, 0 SSR raymarching)
// - Random sparse analytical noise-gradient ripples (calm glassy patches + ripples)
// - Fresnel reflection of analytical sky + fast cloud reflection
// - Beer-Lambert depth absorption via opaque depthtex1
// - Premultiplied alpha trick for crisp additive sun glint & Fresnel sky
// =============================================================================

vec3 calcWaterNormal(vec3 worldPosMod64, vec3 baseNormal, float timeSec, float rainStrength) {
    // Only ripple top/bottom faces prominently; keep waterfalls subtle
    float flatWeight = clamp01(abs(baseNormal.y));
    if (flatWeight < 0.1) {
        return baseNormal;
    }

    // Very wide, flat, barely-visible directional swells (2 staggered 16x16 grids)
    vec3 riseA = evalDirectionalWaveletGrid(worldPosMod64.xz, 0.0625, 3, timeSec, 0.12, rainStrength, vec2(0.0), 0, 0.0);
    vec3 riseB = evalDirectionalWaveletGrid(worldPosMod64.xz, 0.0625, 3, timeSec, 0.12, rainStrength, vec2(0.5), 193, 0.5);

    float rainBoost = 1.0 + 0.65 * rainStrength;
    vec2 totalGrad = (riseA.yz + riseB.yz) * (0.075 * rainBoost);

    return normalize(vec3(-totalGrad.x * flatWeight, baseNormal.y, -totalGrad.y * flatWeight));
}

vec4 shadeOverworldWater(
    vec3 baseWaterLinear,
    vec3 worldPosMod64,
    vec3 baseNormal,
    vec3 feetPos,
    vec3 viewDir,
    vec3 cameraPos,
    float skyLight,
    float blockLight,
    float shadowFactor,
    float waterThickness,
    bool eyeInWater,
    AtmosphereState atmo,
    float timeSec
) {
    vec3 N = calcWaterNormal(worldPosMod64, baseNormal, timeSec, atmo.rainStrength);
    if (eyeInWater) {
        N = -N;
    }
    vec3 V = -viewDir;
    float NdotV = max(dot(N, V), 0.04);
    float fresnel = fresnelSchlick(NdotV, 0.025);

    // Beer-Lambert optical thickness -> crystal-clear shallows, rich deep water
    float depthAlpha = 1.0 - exp(-waterThickness * 0.42);
    float alpha = eyeInWater ? mix(0.18, 0.72, fresnel) : clamp(mix(0.22, 0.94, depthAlpha) + fresnel * 0.45, 0.18, 0.97);

    // Deep vs shallow water scattering tint
    vec3 deepTint = vec3(0.02, 0.16, 0.24) * clamp01(0.35 + skyLight * 0.65);
    vec3 shallowTint = baseWaterLinear * vec3(0.25, 0.62, 0.68);
    vec3 waterTint = mix(shallowTint, deepTint, clamp01(depthAlpha));

    float skyVis = pow(skyLight, 1.35);
    float shadow = mix(1.0, shadowFactor, atmo.shadowFade);
    vec3 waterLit = waterTint * (atmo.ambientSkyColor * skyVis * 1.4 + atmo.directLightColor * (0.25 * shadow + 0.08) + vec3(0.18, 0.09, 0.03) * blockLight);

    // Reflected sky (gradient + fast single-tap cloud tint, skipping star/full-FBM cost)
    vec3 reflDir = reflect(viewDir, N);
    reflDir.y = max(reflDir.y, 0.02);
    vec3 reflColor = evalSkyGradient(reflDir, atmo);
#ifdef CLOUDS_ENABLED
    float reflInvY = 1.0 / max(reflDir.y, 0.06);
    vec2 reflCloudPos = cameraPos.xz * 0.0014 + reflDir.xz * (0.48 * reflInvY) + vec2(timeSec * 0.0065, timeSec * 0.0022);
    float reflCloudDensity = valueNoise2D(reflCloudPos);
    float reflCloudAlpha = smoothstep(0.54, 0.80, reflCloudDensity) * smoothstep(0.02, 0.18, reflDir.y) * 0.72;
    vec3 reflCloudCol = atmo.directLightColor * 0.65 + atmo.ambientSkyColor * 1.9;
    reflColor = mix(reflColor, reflCloudCol, reflCloudAlpha);
#endif
    reflColor *= skyVis;

    // Crisp sun/moon specular sparkle on waves
    vec3 H = normalize(atmo.shadowLightDir + V);
    float NdotH = clamp01(dot(N, H));
    float spec = pow(NdotH, 196.0) * shadow * 2.8;
    vec3 sunSparkle = atmo.directLightColor * (spec * (1.0 - 0.85 * atmo.rainStrength));

    // Compensate additive Fresnel + specular against hardware SRC_ALPHA blending
    vec3 additiveLight = reflColor * fresnel + sunSparkle;
    vec3 outRgb = waterLit + additiveLight / max(alpha, 0.06);
    return vec4(outRgb, alpha);
}

#endif // LIB_WATER_GLSL
