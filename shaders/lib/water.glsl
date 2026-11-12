#ifndef LIB_WATER_GLSL
#define LIB_WATER_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/noise.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/lighting.glsl"

// =============================================================================
// Clean MakeUp-UltraFast-Inspired Water Shader
// - Dual-scrolling anisotropic value-noise gradient ripples (0 normal textures)
// - Distance-only water turbidity (air distance before water surface excluded)
// - Light-intensity & light-tint driven water volume scattering
// - Analytical sky/cloud/sun/moon Fresnel reflections + 2-lobe specular glint
// =============================================================================

// Returns world-space perturbed normal for realistic water ripples
vec3 calcWaterNormal(
    vec3 worldPosMod64,
    vec3 baseNormal,
    float viewDist,
    float timeSec,
    float rainStrength
) {
    float flatWeight = clamp01(abs(baseNormal.y));
    if (flatWeight < 0.1) {
        return baseNormal;
    }

    // Two scrolling anisotropic layers (non-square cells break grid symmetry)
    vec2 pBroad = worldPosMod64.xz * vec2(0.50, 0.25) + vec2(0.32, 0.18) * timeSec;
    vec3 broad = valueNoise2DGradAniso(pBroad, ivec2(31, 15), ivec2(11, 29));

    vec2 pFine = worldPosMod64.xz * vec2(0.50, 1.00) + vec2(-0.26, 0.44) * timeSec;
    vec3 fine = valueNoise2DGradAniso(pFine, ivec2(31, 63), ivec2(73, 137));

    // Smoothly attenuate high-frequency ripples with distance to avoid horizon aliasing
    float detailFade = 1.0 / (1.0 + viewDist * 0.032);
    float rainBoost = 1.0 + 0.55 * rainStrength;

    vec2 gradBroad = broad.yz * vec2(0.50, 0.25);
    vec2 gradFine  = fine.yz  * vec2(0.50, 1.00) * detailFade;
    vec2 totalGrad = (gradBroad * 0.14 + gradFine * 0.065) * (rainBoost * flatWeight);

    return normalize(vec3(-totalGrad.x, baseNormal.y, -totalGrad.y));
}

vec4 shadeOverworldWater(
    vec3 baseWaterLinear,
    vec3 worldPosMod64,
    vec3 baseNormal,
    vec3 feetPos,
    vec3 viewDir,
    float viewDist,
    vec3 cameraPos,
    float skyLight,
    float blockLight,
    float shadowFactor,
    float waterPathDist,
    bool eyeInWater,
    float handLightLevel,
    float nightVision,
    AtmosphereState atmo,
    float timeSec
) {
    vec3 N = calcWaterNormal(worldPosMod64, baseNormal, viewDist, timeSec, atmo.rainStrength);
    if (eyeInWater) {
        N = -N;
    }

    vec3 V = -viewDir;
    float NdotV = max(dot(N, V), 0.03);
    float fresnel = fresnelSchlick(NdotV, 0.02);

    // Turbidity strictly from distance inside water (air path excluded)
    float absorptionRate = eyeInWater ? 0.14 : 0.28;
    float depthAlpha = 1.0 - exp(-max(waterPathDist, 0.0) * absorptionRate);
    depthAlpha = clamp(depthAlpha, eyeInWater ? 0.02 : 0.08, 0.96);

    // Physical water fill driven by active light intensity & tint (day/sunset/night/shadow/torch)
    float skyVis = skyLight * sqrt(max(skyLight, 0.0));
    float skyLightMask = smoothstep(0.02, 0.28, skyLight);
    float shadow = mix(1.0, shadowFactor, atmo.shadowFade) * skyLightMask;
    float NdotL = clamp01(dot(N, atmo.shadowLightDir));

    vec3 directWater  = atmo.directLightColor * ((0.18 + 0.82 * NdotL) * shadow);
    vec3 ambientWater = mix(atmo.ambientGroundColor, atmo.ambientSkyColor, 0.72) * (skyVis * 1.35);
    vec3 torchWater   = evalBlockLight(blockLight) + evalDynamicHandlight(feetPos, N, handLightLevel);
    vec3 caveFloor    = vec3(0.010, 0.015, 0.020) * (1.0 + nightVision * 12.0);
    if (nightVision > 0.01) {
        ambientWater += vec3(0.18, 0.22, 0.24) * nightVision;
    }
    vec3 waterIrradiance = directWater + ambientWater + torchWater + caveFloor;

    // Realistic muted natural water scattering (clear neutral shallows -> deep oceanic blue-slate)
    vec3 biomeShallow = mix(baseWaterLinear, baseWaterLinear * vec3(0.65, 0.84, 0.90), 0.35);
    vec3 biomeDeep    = baseWaterLinear * vec3(0.08, 0.22, 0.34);
    vec3 waterAlbedo  = mix(biomeShallow, biomeDeep, depthAlpha);
    vec3 waterFill    = waterAlbedo * waterIrradiance;

    // Physical Fresnel sky/cloud/sun/moon reflection
    vec3 reflColor;
    if (eyeInWater) {
        reflColor = (atmo.ambientSkyColor * skyVis + atmo.directLightColor * (0.20 * shadow)) * vec3(0.16, 0.38, 0.52);
    } else {
        vec3 reflDir = reflect(viewDir, N);
        if (reflDir.y < 0.0) {
            reflDir.y = -reflDir.y * 0.35 + 0.01;
        }
        reflColor = evalWaterReflectionSky(reflDir, cameraPos, atmo, timeSec) * skyVis;
    }

    // 2-lobe analytical sun/moon specular highlight (squarings avoid pow())
    vec3 H = normalize(atmo.shadowLightDir + V);
    float NdotH = clamp01(dot(N, H));
    float h2 = NdotH * NdotH;
    float h4 = h2 * h2;
    float h8 = h4 * h4;
    float h16 = h8 * h8;
    float h32 = h16 * h16;
    float h64 = h32 * h32;
    float h512 = h64 * h64;
    h512 = h512 * h512;
    h512 = h512 * h512;

    float specStrength = shadow * (1.0 - 0.88 * atmo.rainStrength) * (eyeInWater ? 0.35 : 1.0);
    vec3 sunSparkle = atmo.directLightColor * ((h64 * 0.12 + h512 * 3.0) * specStrength);

    // Energy-conserving OpenGL SRC_ALPHA / ONE_MINUS_SRC_ALPHA blend compensation
    float effectiveAlpha = clamp(1.0 - (1.0 - depthAlpha) * (1.0 - fresnel), 0.08, 0.98);
    vec3 outRgb = ((1.0 - fresnel) * depthAlpha * waterFill + fresnel * reflColor + sunSparkle) / effectiveAlpha;
    return vec4(max(outRgb, vec3(0.0)), effectiveAlpha);
}

#endif // LIB_WATER_GLSL
