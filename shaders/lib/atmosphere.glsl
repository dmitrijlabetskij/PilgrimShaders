#ifndef LIB_ATMOSPHERE_GLSL
#define LIB_ATMOSPHERE_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/noise.glsl"

// =============================================================================
// Analytical Atmosphere, Procedural Sun/Moon/Stars, Clouds & Aerial Fog
// Zero LUT / sky-texture reads. Pure analytical scattering approximations.
// =============================================================================

struct AtmosphereState {
    vec3 sunDir;
    vec3 moonDir;
    vec3 shadowLightDir;
    float dayFactor;
    float sunsetFactor;
    float nightFactor;
    float rainStrength;
    float shadowFade;
    vec3 zenithColor;
    vec3 horizonColor;
    vec3 mieColor;
    vec3 directLightColor;
    vec3 ambientSkyColor;
    vec3 ambientGroundColor;
};

AtmosphereState buildAtmosphere(vec3 sunDir, vec3 shadowLightDir, float rainStrength) {
    AtmosphereState atmo;
    atmo.sunDir = normalize(sunDir);
    atmo.moonDir = -atmo.sunDir;
    atmo.shadowLightDir = normalize(shadowLightDir);
    atmo.rainStrength = clamp01(rainStrength);

    float sunY = atmo.sunDir.y;
    atmo.dayFactor = smoothstep(-0.08, 0.22, sunY);
    atmo.nightFactor = smoothstep(0.06, -0.16, sunY);
    atmo.sunsetFactor = clamp01(1.0 - abs(sunY - 0.02) * 5.0) * smoothstep(-0.20, -0.02, sunY);
    atmo.shadowFade = smoothstep(0.015, 0.14, atmo.shadowLightDir.y) * (1.0 - 0.80 * atmo.rainStrength);

    // Sky zenith palette: night -> golden hour -> noon
    vec3 zenithNight  = vec3(0.008, 0.014, 0.042);
    vec3 zenithSunset = vec3(0.055, 0.125, 0.400);
    vec3 zenithDay    = vec3(0.048, 0.240, 0.800);
    vec3 zenith = mix(zenithNight, zenithDay, atmo.dayFactor);
    zenith = mix(zenith, zenithSunset, atmo.sunsetFactor * 0.82);

    // Sky horizon palette
    vec3 horizonNight  = vec3(0.020, 0.032, 0.080);
    vec3 horizonSunset = vec3(1.180, 0.370, 0.105);
    vec3 horizonDay    = vec3(0.330, 0.640, 0.950);
    vec3 horizon = mix(horizonNight, horizonDay, atmo.dayFactor);
    horizon = mix(horizon, horizonSunset, atmo.sunsetFactor * 0.90);

    // Moody slate blue during rain
    float overcastLuma = mix(0.025, 0.30, atmo.dayFactor);
    vec3 rainZenith  = vec3(0.72, 0.82, 0.95) * overcastLuma;
    vec3 rainHorizon = vec3(0.84, 0.90, 0.98) * (overcastLuma * 1.35);
    atmo.zenithColor  = mix(zenith,  rainZenith,  atmo.rainStrength * 0.82);
    atmo.horizonColor = mix(horizon, rainHorizon, atmo.rainStrength * 0.85);

    // Mie forward-scattering tint around sun
    vec3 mieDay    = vec3(1.00, 0.94, 0.84);
    vec3 mieSunset = vec3(1.45, 0.56, 0.20);
    atmo.mieColor  = mix(mieDay, mieSunset, atmo.sunsetFactor) * (1.0 - 0.80 * atmo.rainStrength);

    // Direct sun/moon light color (daylight stays crisp; night moonlight is soft and moody)
    vec3 sunLightNoon   = vec3(1.95, 1.80, 1.58);
    vec3 sunLightSunset = vec3(1.95, 0.78, 0.30);
    vec3 moonLight      = vec3(0.042, 0.060, 0.105);
    vec3 sunDirect = mix(sunLightSunset, sunLightNoon, smoothstep(0.0, 0.32, max(sunY, 0.0)));
    vec3 direct = mix(moonLight, sunDirect, smoothstep(-0.04, 0.08, sunY));
    // Fade direct intensity softly during dawn/dusk shadow-flip transition
    float lightSwitchFade = smoothstep(0.01, 0.12, atmo.shadowLightDir.y);
    atmo.directLightColor = direct * lightSwitchFade * (1.0 - 0.78 * atmo.rainStrength);

    // Hemisphere sky ambient (soft fill at night so moon shadows aren't overly harsh)
    vec3 nightFloor = mix(vec3(0.006, 0.009, 0.016), vec3(0.010, 0.014, 0.022), atmo.dayFactor);
    atmo.ambientSkyColor = mix(atmo.zenithColor, atmo.horizonColor, 0.45) * mix(0.42, 0.34, atmo.dayFactor) + nightFloor;
    atmo.ambientGroundColor = atmo.ambientSkyColor * mix(0.56, 0.36, atmo.dayFactor);

    return atmo;
}

void packAtmosphereVaryings(
    AtmosphereState atmo,
    out vec4 outZenith,
    out vec4 outHorizon,
    out vec4 outMie,
    out vec4 outDirect,
    out vec4 outAmbSky
) {
    outZenith  = vec4(atmo.zenithColor, atmo.dayFactor);
    outHorizon = vec4(atmo.horizonColor, atmo.sunsetFactor);
    outMie     = vec4(atmo.mieColor, atmo.nightFactor);
    outDirect  = vec4(atmo.directLightColor, atmo.shadowFade);
    outAmbSky  = vec4(atmo.ambientSkyColor, atmo.rainStrength);
}

AtmosphereState unpackAtmosphereVaryings(
    vec4 vZenith,
    vec4 vHorizon,
    vec4 vMie,
    vec4 vDirect,
    vec4 vAmbSky,
    vec3 vAmbGround,
    vec3 vSunDir,
    vec3 vShadowDir
) {
    AtmosphereState atmo;
    atmo.sunDir = vSunDir;
    atmo.moonDir = -vSunDir;
    atmo.shadowLightDir = vShadowDir;
    atmo.dayFactor = vZenith.a;
    atmo.sunsetFactor = vHorizon.a;
    atmo.nightFactor = vMie.a;
    atmo.rainStrength = vAmbSky.a;
    atmo.shadowFade = vDirect.a;
    atmo.zenithColor = vZenith.rgb;
    atmo.horizonColor = vHorizon.rgb;
    atmo.mieColor = vMie.rgb;
    atmo.directLightColor = vDirect.rgb;
    atmo.ambientSkyColor = vAmbSky.rgb;
    atmo.ambientGroundColor = vAmbGround;
    return atmo;
}

// Base analytical Rayleigh + Mie sky without discs/stars/clouds (used for fog & base sky)
vec3 evalSkyGradient(vec3 viewDir, AtmosphereState atmo) {
    float elev = max(viewDir.y, 0.0);
    float horizonT = exp(-elev * 5.2);
    vec3 sky = mix(atmo.zenithColor, atmo.horizonColor, horizonT);

    // Subtle darkening below horizon for seamless reflections/sky dome bottom
    float belowHorizon = clamp01(-viewDir.y * 4.0);
    sky = mix(sky, atmo.horizonColor * 0.38, belowHorizon);

    // Mie sun halo (stronger near sunset/horizon) - squaring avoids expensive pow() calls
    float sunCos = max(dot(viewDir, atmo.sunDir), 0.0);
    float sunAboveHorizon = smoothstep(-0.18, 0.12, atmo.sunDir.y);
    float sc2 = sunCos * sunCos;
    float sc6 = sc2 * sc2 * sc2;
    float sc12 = sc6 * sc6;
    float sc36 = sc12 * sc12 * sc12;
    float mieBroad = sc6 * (0.16 + 0.55 * atmo.sunsetFactor);
    float mieTight = sc36 * (0.32 + 0.65 * atmo.sunsetFactor);
    sky += atmo.mieColor * (mieBroad + mieTight) * sunAboveHorizon;

    // Subtle cool moon aura
    float moonCos = max(dot(viewDir, atmo.moonDir), 0.0);
    float mc2 = moonCos * moonCos;
    float mc4 = mc2 * mc2;
    float mc16 = mc4 * mc4 * mc4 * mc4;
    float moonAura = mc16 * 0.065 * atmo.nightFactor * (1.0 - 0.85 * atmo.rainStrength);
    sky += vec3(0.35, 0.52, 0.85) * moonAura;

    return sky;
}

vec3 evalProceduralStars(vec3 viewDir, AtmosphereState atmo, float timeSec) {
    float starVisibility = atmo.nightFactor * (1.0 - atmo.rainStrength) * smoothstep(0.02, 0.25, viewDir.y);
    if (starVisibility <= 0.001) {
        return vec3(0.0);
    }

    // Spherical cell hash (0 texture reads)
    vec3 p = viewDir * 220.0;
    ivec3 cell = ivec3(floor(p));
    vec3 f = fract(p) - 0.5;
    float h = hash31(cell);
    if (h < 0.986) {
        return vec3(0.0);
    }

    float dist = length(f);
    float shape = smoothstep(0.42, 0.06, dist);
    float twinkle = 0.72 + 0.28 * sin(timeSec * (1.8 + fract(h * 73.1) * 3.0) + h * 100.0);
    float temp = fract(h * 41.7);
    vec3 starTint = mix(vec3(1.0, 0.82, 0.68), vec3(0.75, 0.88, 1.0), temp);
    return starTint * (shape * twinkle * starVisibility * 1.45);
}

vec4 evalProceduralClouds(vec3 viewDir, vec3 cameraPos, AtmosphereState atmo, float timeSec) {
#ifndef CLOUDS_ENABLED
    return vec4(0.0);
#else
    if (viewDir.y <= 0.015) {
        return vec4(0.0);
    }

    // 5-slice pseudo-volumetric cloud slab (flat shaded bases, bright puffy sunlit tops)
    float domeInvY = 1.0 / (viewDir.y + 0.09);
    float slabParallax = min(domeInvY, 4.0);
    vec2 wind = vec2(timeSec * 0.0075, timeSec * 0.0024);
    vec2 basePos = cameraPos.xz * 0.0020 + viewDir.xz * (1.15 * domeInvY) + wind;
    vec2 slabOffset = viewDir.xz * (0.26 * slabParallax);

    float coverage = mix(0.56, 0.39, atmo.rainStrength);
    vec3 litColor = atmo.directLightColor * 0.78 + atmo.ambientSkyColor * 2.45;
    vec3 darkColor = mix(atmo.ambientSkyColor * 1.25, atmo.horizonColor * 0.32, 0.45);

    // Silver-lining toward sun
    float sa = max(dot(viewDir, atmo.sunDir), 0.0);
    float sa2 = sa * sa;
    float sa4 = sa2 * sa2;
    float sunAlign = (sa4 * sa4) * smoothstep(-0.12, 0.15, atmo.sunDir.y);

    vec3 accumColor = vec3(0.0);
    float transmittance = 1.0;
    const int STEPS = 5;
    for (int i = 0; i < STEPS; ++i) {
        // Height fraction from bottom (0.10) to top (0.90) of the cloud slab
        float h = (float(i) + 0.5) / float(STEPS);
        vec2 samplePos = basePos + slabOffset * h;
        // Flat base fading sharply above h=0.2, rounded cumulus dome narrowing toward h=1.0
        float heightShape = smoothstep(0.0, 0.22, h) * smoothstep(1.0, 0.35, h);
        float rawDensity = cloudShapeSlice(samplePos);
        // Slightly tighten edge near top to sculpt puffy domes over wider bases
        float localThreshold = coverage + (1.0 - heightShape) * 0.14;
        float sliceAlpha = smoothstep(localThreshold, localThreshold + 0.09, rawDensity) * 0.58;
        if (sliceAlpha > 0.002) {
            float lightMix = clamp01(0.20 + 0.78 * h + (rawDensity - localThreshold) * 0.85);
            vec3 sliceCol = mix(darkColor, litColor, lightMix);
            sliceCol += atmo.mieColor * (sunAlign * (1.0 - sliceAlpha * 0.7) * 0.65);

            accumColor += transmittance * sliceCol * sliceAlpha;
            transmittance *= (1.0 - sliceAlpha);
            if (transmittance < 0.04) {
                break;
            }
        }
    }

    float totalAlpha = 1.0 - transmittance;
    if (totalAlpha <= 0.001) {
        return vec4(0.0);
    }
    vec3 cloudColor = accumColor / totalAlpha;

    // Seamless blend into distant horizon haze
    float horizonFade = smoothstep(0.015, 0.18, viewDir.y);
    totalAlpha *= horizonFade * 0.94;
    cloudColor = mix(atmo.horizonColor, cloudColor, horizonFade);

    return vec4(cloudColor, totalAlpha);
#endif
}

// Complete Overworld sky (gradient + stars + sun/moon discs + clouds)
vec3 evalOverworldSky(
    vec3 viewDir,
    vec3 cameraPos,
    AtmosphereState atmo,
    float timeSec,
    bool includeDiscsAndClouds
) {
    vec3 sky = evalSkyGradient(viewDir, atmo);
    if (!includeDiscsAndClouds) {
        return sky;
    }

    // Procedural twinkling stars
    sky += evalProceduralStars(viewDir, atmo, timeSec);

    // Procedural Sun disc with soft corona
    float sunDot = dot(viewDir, atmo.sunDir);
    float sunDisc = smoothstep(0.9987, 0.9994, sunDot);
    float sunShow = smoothstep(-0.06, 0.04, atmo.sunDir.y) * (1.0 - 0.88 * atmo.rainStrength);
    vec3 sunDiscColor = mix(vec3(1.0, 0.45, 0.15), vec3(1.0, 0.96, 0.88), smoothstep(0.0, 0.25, max(atmo.sunDir.y, 0.0)));
    sky += sunDiscColor * (sunDisc * 14.0 * sunShow);

    // Procedural Moon disc with simple crater shading
    float moonDot = dot(viewDir, atmo.moonDir);
    float moonDisc = smoothstep(0.9990, 0.9995, moonDot);
    if (moonDisc > 0.001) {
        vec3 right = normalize(cross(vec3(0.0, 1.0, 0.001), atmo.moonDir));
        vec3 up = cross(atmo.moonDir, right);
        vec2 moonUV = vec2(dot(viewDir, right), dot(viewDir, up)) * 95.0;
        float crater = valueNoise2D(moonUV * 2.2) * 0.35 + valueNoise2D(moonUV * 5.0) * 0.18;
        float moonShow = smoothstep(-0.04, 0.08, atmo.moonDir.y) * (1.0 - 0.85 * atmo.rainStrength);
        sky += vec3(0.75, 0.84, 1.0) * (1.65 * (0.75 + crater * 0.45) * moonDisc * moonShow);
    }

    // Analytical clouds layered smoothly in front of stars/sun/moon
    vec4 clouds = evalProceduralClouds(viewDir, cameraPos, atmo, timeSec);
    sky = mix(sky, clouds.rgb, clouds.a);

    return sky;
}

// Lightweight sky/sun/moon/cloud evaluation for rippled water reflections (~70% fewer hashes)
vec3 evalWaterReflectionSky(
    vec3 viewDir,
    vec3 cameraPos,
    AtmosphereState atmo,
    float timeSec
) {
    vec3 sky = evalSkyGradient(viewDir, atmo);

    float sunDot = dot(viewDir, atmo.sunDir);
    float sunDisc = smoothstep(0.9987, 0.9994, sunDot);
    float sunShow = smoothstep(-0.06, 0.04, atmo.sunDir.y) * (1.0 - 0.88 * atmo.rainStrength);
    vec3 sunDiscColor = mix(vec3(1.0, 0.45, 0.15), vec3(1.0, 0.96, 0.88), smoothstep(0.0, 0.25, max(atmo.sunDir.y, 0.0)));
    sky += sunDiscColor * (sunDisc * 12.0 * sunShow);

    float moonDot = dot(viewDir, atmo.moonDir);
    float moonDisc = smoothstep(0.9990, 0.9995, moonDot);
    float moonShow = smoothstep(-0.04, 0.08, atmo.moonDir.y) * (1.0 - 0.85 * atmo.rainStrength);
    sky += vec3(0.75, 0.84, 1.0) * (1.4 * moonDisc * moonShow);

#ifdef CLOUDS_ENABLED
    if (viewDir.y > 0.015) {
        float domeInvY = 1.0 / (viewDir.y + 0.09);
        vec2 cloudPos = cameraPos.xz * 0.0022 + viewDir.xz * (1.28 * domeInvY) + vec2(timeSec * 0.0075, timeSec * 0.0024);
        float density = cloudShapeShadow(cloudPos);
        float coverage = mix(0.54, 0.37, atmo.rainStrength);
        float alpha = smoothstep(coverage, coverage + 0.10, density);
        if (alpha > 0.001) {
            vec2 sunStep = normalize(atmo.shadowLightDir.xz + vec2(1e-4)) * 0.090;
            float sFar = cloudShapeShadow(cloudPos + sunStep);
            float selfLit = clamp01(0.74 - (sFar - density) * 3.8);
            vec3 litColor = atmo.directLightColor * 0.78 + atmo.ambientSkyColor * 2.45;
            vec3 darkColor = mix(atmo.ambientSkyColor * 1.25, atmo.horizonColor * 0.32, 0.45);
            vec3 cloudColor = mix(darkColor, litColor, selfLit);
            float horizonFade = smoothstep(0.015, 0.18, viewDir.y);
            cloudColor = mix(atmo.horizonColor, cloudColor, horizonFade);
            sky = mix(sky, cloudColor, alpha * horizonFade * 0.92);
        }
    }
#endif

    return sky;
}

// Atmospheric aerial fog for Overworld terrain & translucents
vec3 applyOverworldFog(
    vec3 color,
    vec3 viewDir,
    vec3 feetPos,
    float viewDist,
    float farPlane,
    AtmosphereState atmo,
    float cameraY
) {
    float density = FOG_DENSITY;
    if (density <= 0.001) {
        return color;
    }

    // Distance exponential fog + subtle valley height mist
    float distRatio = viewDist / max(farPlane, 32.0);
    float worldY = feetPos.y + cameraY;
    float heightMist = exp(-max(worldY - 62.0, 0.0) * 0.032) * (0.28 + 0.55 * atmo.rainStrength + 0.35 * atmo.sunsetFactor);

    float fogAmount = 1.0 - exp(-viewDist * (0.0009 + 0.0038 * atmo.rainStrength) * density);
    fogAmount += (1.0 - exp(-viewDist * 0.0028 * heightMist * density)) * 0.35;

    // Seamless blend to sky right before far render edge
    float borderFade = smoothstep(0.74, 0.99, distRatio);
    fogAmount = clamp01(max(fogAmount, borderFade));

    vec3 fogColor = evalSkyGradient(viewDir, atmo);
    return mix(color, fogColor, fogAmount);
}

// Shared underwater fog color used identically by deferred sky/unloaded chunks and medium fog
vec3 evalUnderwaterFogColor(vec3 viewDir, AtmosphereState atmo) {
    vec3 lightRef = atmo.ambientSkyColor * 0.42 + atmo.directLightColor * 0.055;
    vec3 baseUw = lightRef * vec3(0.16, 0.52, 0.72) + vec3(0.002, 0.006, 0.012);
    float vertShade = 1.0 + 0.32 * max(viewDir.y, 0.0) - 0.36 * max(-viewDir.y, 0.0);
    return baseUw * vertShade;
}

// Unified medium / blindness fog shared across deferred, water, and forward passes
vec3 applyOverworldMediumAndFog(
    vec3 color,
    vec3 viewDir,
    vec3 feetPos,
    float viewDist,
    float farPlane,
    AtmosphereState atmo,
    float cameraY,
    int eyeInWater,
    float blindness,
    float darknessFactor
) {
    if (eyeInWater == 1) {
        float waterFog = 1.0 - exp(-viewDist * 0.080);
        float borderFade = smoothstep(0.70, 0.96, viewDist / max(farPlane, 32.0));
        waterFog = clamp01(max(waterFog, borderFade));
        vec3 uwFogColor = evalUnderwaterFogColor(viewDir, atmo);
        color = mix(color, uwFogColor, waterFog);
    } else if (eyeInWater == 2) {
        color = mix(color, vec3(1.10, 0.28, 0.04), clamp01(1.0 - exp(-viewDist * 0.45)));
    } else if (eyeInWater == 3) {
        color = mix(color, vec3(0.65, 0.78, 0.90), clamp01(1.0 - exp(-viewDist * 0.35)));
    } else {
        color = applyOverworldFog(color, viewDir, feetPos, viewDist, farPlane, atmo, cameraY);
    }

    float blind = clamp01(max(blindness, darknessFactor));
    return color * mix(1.0, exp(-viewDist * 0.18), blind);
}

// Deep violet/nebula sky for The End (0 texture reads)
vec3 evalEndSky(vec3 viewDir, float timeSec) {
    float elev = abs(viewDir.y);
    vec3 base = mix(vec3(0.055, 0.022, 0.095), vec3(0.012, 0.006, 0.028), smoothstep(0.0, 0.85, elev));
    float neb = cloudFbm(viewDir.xz / (abs(viewDir.y) + 0.45) * 1.4 + vec2(timeSec * 0.003, 0.0));
    base += vec3(0.11, 0.04, 0.20) * smoothstep(0.45, 0.85, neb) * 0.65;

    vec3 cell = floor(viewDir * 200.0);
    float h = hash31(ivec3(cell));
    if (h > 0.990) {
        base += vec3(0.65, 0.45, 1.0) * ((h - 0.990) * 120.0);
    }
    return base;
}

#endif // LIB_ATMOSPHERE_GLSL
