#ifndef LIB_LIGHTING_GLSL
#define LIB_LIGHTING_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/atmosphere.glsl"

// =============================================================================
// Unified PBR-Lite Surface Lighting (Deferred Opaque + Forward Translucent)
// Zero extra texture reads: uses only unpacked G-buffer + AtmosphereState.
// =============================================================================

struct LightingInputs {
    vec3 albedoLinear;
    vec3 worldNormal;
    vec3 feetPos;
    vec3 viewDir; // Normalized world ray from camera to surface
    float skyLight;
    float blockLight;
    float shadowFactor;
    int matId;
    float handLightLevel; // 0..15 normalized to 0..1
    float nightVision;
};

vec3 evalDynamicHandlight(vec3 feetPos, vec3 worldNormal, float handLightLevel) {
#ifndef DYNAMIC_HANDLIGHT
    return vec3(0.0);
#else
    if (handLightLevel <= 0.01) {
        return vec3(0.0);
    }
    float distSq = dot(feetPos, feetPos);
    float radius = 14.0 * handLightLevel;
    if (distSq > radius * radius) {
        return vec3(0.0);
    }
    vec3 toEye = normalize(-feetPos + vec3(0.0, 1e-4, 0.0));
    float atten = 1.0 / (1.0 + 0.16 * distSq);
    float falloff = smoothstep(radius, radius * 0.25, sqrt(distSq));
    float wrapNdotL = 0.35 + 0.65 * max(dot(worldNormal, toEye), 0.0);
    return vec3(1.15, 0.62, 0.24) * (handLightLevel * atten * falloff * wrapNdotL * 1.45);
#endif
}

vec3 evalBlockLight(float blockLight) {
    // Rich warm amber-orange falloff; gently brightens toward core
    float b = clamp01(blockLight);
    float curve = b * b * (1.0 + 1.15 * b);
    vec3 warmCore = mix(vec3(1.00, 0.48, 0.14), vec3(1.25, 0.85, 0.52), b * b);
    return warmCore * (curve * 1.65);
}

vec3 shadeOverworldSurface(LightingInputs inData, AtmosphereState atmo) {
    vec3 N = inData.worldNormal;
    vec3 L = atmo.shadowLightDir;
    vec3 V = -inData.viewDir; // Toward camera

    bool isFoliage  = (inData.matId == MAT_FOLIAGE);
    bool isEmissive = (inData.matId == MAT_EMISSIVE);
    bool isSpecular = (inData.matId == MAT_SPECULAR);

    // Direct sun / moon irradiance
    float rawNdotL = dot(N, L);
    float NdotL = isFoliage
        ? clamp((rawNdotL + 0.38) / 1.38, 0.0, 1.0)
        : clamp01(rawNdotL);

    float shadow = mix(1.0, inData.shadowFactor, atmo.shadowFade);
    vec3 direct = atmo.directLightColor * (NdotL * shadow);

    // Backlit foliage subsurface scattering (warm translucent leaf glow)
    if (isFoliage) {
        float bDot = clamp01(dot(-V, -L));
        float backScatter = bDot * bDot * bDot;
        direct += atmo.directLightColor * (backScatter * shadow * 0.42);
    }

    // Hemisphere sky ambient + subtle directional bounce contrast so shadow walls read 3D
    float skyVis = inData.skyLight * sqrt(max(inData.skyLight, 0.0));
    float hemi = N.y * 0.5 + 0.5;
    vec3 skyBounce = mix(atmo.ambientGroundColor, atmo.ambientSkyColor, hemi);
    float sunBounce = 0.85 + 0.15 * clamp(dot(N, vec3(-L.x, 0.4, -L.z)), -1.0, 1.0);
    vec3 ambient = skyBounce * (skyVis * sunBounce);

    // Subtle cave minimum so unlit caves stay atmospheric rather than dead-flat clipping
    vec3 caveFloor = vec3(0.018, 0.020, 0.026) * (1.0 + inData.nightVision * 12.0);
    ambient = max(ambient, caveFloor * (0.65 + 0.35 * hemi));
    if (inData.nightVision > 0.01) {
        ambient += vec3(0.22, 0.24, 0.26) * inData.nightVision;
    }

    // Block light + dynamic handlight
    vec3 torch = evalBlockLight(inData.blockLight) + evalDynamicHandlight(inData.feetPos, N, inData.handLightLevel);
    // Slightly soften direct sunlight shadow contrast where torch dominates
    vec3 totalLight = direct + ambient + torch;

    vec3 color = inData.albedoLinear * totalLight;

    // Specular highlight for metallic/gem/ice surfaces or outdoor rain-wet tops
    float wetness = atmo.rainStrength * smoothstep(0.65, 0.98, inData.skyLight) * clamp01(N.y);
    if (isSpecular || wetness > 0.05) {
        vec3 H = normalize(L + V);
        float specPow = isSpecular ? 48.0 : 28.0;
        float specStrength = isSpecular ? 0.55 : (0.35 * wetness);
        float NdotH = clamp01(dot(N, H));
        float fresnel = fresnelSchlick(clamp01(dot(N, V)), isSpecular ? 0.08 : 0.02);
        vec3 spec = atmo.directLightColor * (pow(NdotH, specPow) * shadow * specStrength);
        vec3 skyRefl = mix(atmo.horizonColor, atmo.zenithColor, 0.5) * (fresnel * skyVis * (isSpecular ? 0.45 : 0.30 * wetness));
        color += spec * mix(vec3(1.0), inData.albedoLinear, isSpecular ? 0.5 : 0.0) + skyRefl;
    }

    // Self-emission for glowstone, torches, lava, froglights, sea lanterns
    if (isEmissive) {
        float luma = luminance(inData.albedoLinear);
        float emitMask = smoothstep(0.06, 0.32, luma);
        color += inData.albedoLinear * (emitMask * 2.40);
    }

    return color;
}

vec3 shadeNetherOrEndSurface(LightingInputs inData, bool isEnd) {
    vec3 N = inData.worldNormal;
    float hemi = N.y * 0.5 + 0.5;
    vec3 amb = isEnd
        ? mix(vec3(0.05, 0.03, 0.09), vec3(0.16, 0.11, 0.26), hemi)
        : mix(vec3(0.18, 0.06, 0.04), vec3(0.32, 0.13, 0.08), hemi);
    amb += vec3(0.20) * inData.nightVision;

    vec3 torch = evalBlockLight(inData.blockLight) + evalDynamicHandlight(inData.feetPos, N, inData.handLightLevel);
    vec3 color = inData.albedoLinear * (amb + torch);

    if (inData.matId == MAT_EMISSIVE) {
        float emitMask = smoothstep(0.06, 0.32, luminance(inData.albedoLinear));
        color += inData.albedoLinear * (emitMask * 2.50);
    }
    return color;
}

#endif // LIB_LIGHTING_GLSL
