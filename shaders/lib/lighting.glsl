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
    return vec3(1.02, 0.62, 0.16) * (handLightLevel * atten * falloff * wrapNdotL * 0.95);
#endif
}

vec3 evalBlockLight(float blockLight) {
    // Muted warm golden-yellow torch falloff without white highlight blowout
    float b = clamp01(blockLight);
    float curve = b * b * (0.75 + 0.55 * b);
    vec3 warmYellow = mix(vec3(1.00, 0.54, 0.10), vec3(1.05, 0.70, 0.22), b * b);
    return warmYellow * (curve * 0.95);
}

vec3 shadeOverworldSurface(LightingInputs inData, AtmosphereState atmo) {
    vec3 N = inData.worldNormal;
    vec3 L = atmo.shadowLightDir;
    vec3 V = -inData.viewDir; // Toward camera

    bool isFoliage  = (inData.matId == MAT_FOLIAGE);
    bool isEmissive = (inData.matId == MAT_EMISSIVE);
    bool isSpecular = (inData.matId == MAT_SPECULAR);
    bool isHand     = (inData.matId == MAT_HAND);

    // Direct sun / moon irradiance
    float rawNdotL = dot(N, L);
    float NdotL;
    if (isHand) {
        // Soft wrapped diffuse for first-person hand (prevents harsh dark edges & bobbing flicker)
        NdotL = clamp01(rawNdotL * 0.45 + 0.55);
    } else if (isFoliage) {
        NdotL = clamp((rawNdotL + 0.38) / 1.38, 0.0, 1.0);
    } else {
        NdotL = clamp01(rawNdotL);
    }

    // Gate direct sun/moon irradiance by skyLight so sealed caves never leak sunlight
    // through back-face culled shadow chunks, block corners, or unshadowed forward passes.
    float skyVis = inData.skyLight * sqrt(max(inData.skyLight, 0.0));
    float skyLightMask = smoothstep(0.02, 0.28, inData.skyLight);
    float shadow = isHand
        ? inData.shadowFactor
        : mix(1.0, inData.shadowFactor, atmo.shadowFade) * skyLightMask;
    vec3 direct = atmo.directLightColor * (NdotL * shadow);
    if (isHand) {
        direct *= 0.55;
    }

    // Backlit foliage subsurface scattering (warm translucent leaf glow)
    if (isFoliage) {
        float bDot = clamp01(dot(-V, -L));
        float backScatter = bDot * bDot * bDot;
        direct += atmo.directLightColor * (backScatter * shadow * 0.42);
    }

    // Hemisphere sky ambient + subtle directional bounce contrast so shadow walls read 3D
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
    vec3 torch;
    if (isHand) {
        // Soft roll-off on first-person hand so intense light sources (like lava)
        // give a rich warm amber glow instead of blowing out to pure white
        float bl = inData.blockLight;
        vec3 handBlock = evalBlockLight(bl) * 0.65;
        torch = handBlock + evalDynamicHandlight(inData.feetPos, N, inData.handLightLevel) * 0.40;
    } else {
        torch = evalBlockLight(inData.blockLight)
              + evalDynamicHandlight(inData.feetPos, N, inData.handLightLevel);
    }

    vec3 totalLight = direct + ambient + torch;
    if (isHand) {
        // Soft shoulder compression prevents blowout when standing directly beside lava or torches
        totalLight = totalLight / (1.0 + totalLight * 0.25) * 1.25;
    }

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
        vec3 reflTint = isSpecular ? mix(vec3(1.0), inData.albedoLinear, 0.45) : vec3(1.0);
        vec3 skyRefl = mix(atmo.horizonColor, atmo.zenithColor, 0.5) * (fresnel * skyVis * (isSpecular ? 0.35 : 0.25 * wetness)) * reflTint;
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

vec3 getNetherFogAndSkyColor(vec3 fogCol) {
    vec3 safeFog = max(fogCol, vec3(0.0));
    float maxComp = max(safeFog.r, max(safeFog.g, safeFog.b));
    vec3 biomeNorm = (maxComp > 0.01) ? (safeFog / maxComp) : vec3(1.0, 0.28, 0.08);
    // Dark subterranean void: deep, subtle tinting without washed-out background glow
    return biomeNorm * 0.006 + vec3(0.002, 0.001, 0.001);
}

vec3 shadeNetherOrEndSurface(LightingInputs inData, bool isEnd, vec3 fogCol) {
    vec3 N = inData.worldNormal;
    float hemi = N.y * 0.5 + 0.5;
    bool isHand = (inData.matId == MAT_HAND);

    vec3 amb;
    if (isEnd) {
        amb = mix(vec3(0.12, 0.09, 0.22), vec3(0.34, 0.28, 0.48), hemi);
    } else {
        vec3 safeFog = max(fogCol, vec3(0.0));
        float maxComp = max(safeFog.r, max(safeFog.g, safeFog.b));
        vec3 biomeNorm = (maxComp > 0.01) ? (safeFog / maxComp) : vec3(1.0, 0.28, 0.08);

        // Grim, moody cavern ambient: dark rock silhouettes, subtle lava bounce on ceilings
        vec3 baseAmbient = biomeNorm * 0.004 + vec3(0.003, 0.0015, 0.0015);
        vec3 topLight = biomeNorm * (0.002 + 0.003 * hemi);
        vec3 lavaBounce = vec3(0.06, 0.018, 0.004) * (max(-N.y, 0.0) * 0.35);

        amb = baseAmbient + topLight + lavaBounce;
    }
    amb += vec3(0.35) * inData.nightVision;

    vec3 torch;
    if (isHand) {
        torch = evalBlockLight(inData.blockLight) * 0.40
              + evalDynamicHandlight(inData.feetPos, N, inData.handLightLevel) * 0.30;
    } else {
        float torchScale = isEnd ? 1.15 : 0.45;
        float handScale = isEnd ? 1.00 : 0.65;
        torch = evalBlockLight(inData.blockLight) * torchScale
              + evalDynamicHandlight(inData.feetPos, N, inData.handLightLevel) * handScale;
    }

    vec3 totalLight = amb + torch;
    if (isHand) {
        totalLight = totalLight / (1.0 + totalLight * 0.25) * 1.25;
    }
    vec3 color = inData.albedoLinear * totalLight;

    if (inData.matId == MAT_EMISSIVE) {
        float emitMask = smoothstep(0.05, 0.28, luminance(inData.albedoLinear));
        float boost = isEnd ? 2.40 : 3.36;
        color += inData.albedoLinear * (emitMask * boost);
    }
    return color;
}

#endif // LIB_LIGHTING_GLSL
