#ifndef LIB_WATER_PASS_GLSL
#define LIB_WATER_PASS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/shadows.glsl"
#include "/lib/lighting.glsl"
#include "/lib/water.glsl"
#include "/lib/iris_compat.glsl"

#if defined(VERTEX_SHADER)

#include "/lib/waving.glsl"

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 cameraPosition;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform float frameTimeCounter;
uniform float rainStrength;

in vec4 mc_Entity;

out vec2 vUv;
out vec2 vLm;
out vec4 vColor;
out vec3 vWorldNormal;
out vec3 vFeetPos;
out float vWaterLinearZ;
flat out vec2 vDepthCoeff;
flat out float vIsWater;
flat out vec4 vAtmoZenith;
flat out vec4 vAtmoHorizon;
flat out vec4 vAtmoMie;
flat out vec4 vAtmoDirect;
flat out vec4 vAtmoAmbSky;
flat out vec3 vAtmoAmbGround;
flat out vec3 vAtmoSunDir;
flat out vec3 vAtmoShadowDir;
flat out vec4 vShadowC0;
flat out vec4 vShadowC1;
flat out vec4 vShadowC2;
flat out vec4 vShadowC3;

void main() {
    vUv = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vLm = remapLightmap((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy);
    vColor = gl_Color;

    int blockId = int(mc_Entity.x + 0.5);
    vIsWater = (blockId == BLOCK_WATER) ? 1.0 : 0.0;

    vec3 viewNormal = safeNormalize(gl_NormalMatrix * gl_Normal, vec3(0.0, 1.0, 0.0));
    vWorldNormal = safeNormalize(mat3(gbufferModelViewInverse) * viewNormal, vec3(0.0, 1.0, 0.0));

    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
    vec3 feetPos = (gbufferModelViewInverse * viewPos).xyz;

#ifdef WAVE_ANIMATION
    if (blockId == BLOCK_WATER) {
        vec3 worldMod64 = getWorldPosMod64(feetPos, cameraPosition);
        vec3 wave = calcWavingOffset(worldMod64, BLOCK_WATER, 1.0, frameTimeCounter, rainStrength);
        feetPos += wave;
        viewPos.xyz += mat3(gbufferModelView) * wave;
    }
#endif

    vFeetPos = feetPos;
    vWaterLinearZ = -viewPos.z;
    vDepthCoeff = vec2(
        2.0 * gbufferProjectionInverse[2][3],
        gbufferProjectionInverse[3][3] - gbufferProjectionInverse[2][3]
    );
    vec3 sunDir = viewDirToWorld(sunPosition, gbufferModelViewInverse);
    vec3 shadowDir = viewDirToWorld(shadowLightPosition, gbufferModelViewInverse);
    AtmosphereState atmo = buildAtmosphere(sunDir, shadowDir, rainStrength);
    packAtmosphereVaryings(atmo, vAtmoZenith, vAtmoHorizon, vAtmoMie, vAtmoDirect, vAtmoAmbSky);
    vAtmoAmbGround = atmo.ambientGroundColor;
    vAtmoSunDir    = atmo.sunDir;
    vAtmoShadowDir = atmo.shadowLightDir;

    mat4 shadowVP = shadowProjection * shadowModelView;
    vShadowC0 = shadowVP[0];
    vShadowC1 = shadowVP[1];
    vShadowC2 = shadowVP[2];
    vShadowC3 = shadowVP[3];
    gl_Position = gl_ProjectionMatrix * viewPos;
}

#elif defined(FRAGMENT_SHADER)

uniform sampler2D gtexture;
uniform sampler2D depthtex1;
#if !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
uniform sampler2DShadow shadowtex0;
uniform sampler2D shadowtex1;
#endif

uniform vec3 cameraPosition;
uniform vec3 fogColor;
uniform float frameTimeCounter;
uniform float far;
uniform float nightVision;
uniform float blindness;
uniform float darknessFactor;
uniform int isEyeInWater;
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

in vec2 vUv;
in vec2 vLm;
in vec4 vColor;
in vec3 vWorldNormal;
in vec3 vFeetPos;
in float vWaterLinearZ;
flat in vec2 vDepthCoeff;
flat in float vIsWater;
flat in vec4 vAtmoZenith;
flat in vec4 vAtmoHorizon;
flat in vec4 vAtmoMie;
flat in vec4 vAtmoDirect;
flat in vec4 vAtmoAmbSky;
flat in vec3 vAtmoAmbGround;
flat in vec3 vAtmoSunDir;
flat in vec3 vAtmoShadowDir;
flat in vec4 vShadowC0;
flat in vec4 vShadowC1;
flat in vec4 vShadowC2;
flat in vec4 vShadowC3;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor0;

void main() {
    // Drop vanilla 16x16 pixelated water texture so ripples and reflections stay silky-clean;
    // preserve full texture alpha & albedo for stained glass, ice, slime, honey, and portals.
    vec3 albedoLinear;
    float glassAlpha = 1.0;
    if (vIsWater > 0.5) {
        albedoLinear = srgbToLinear(vColor.rgb * 0.84);
    } else {
        vec4 tex = texture(gtexture, vUv);
        glassAlpha = clamp01(tex.a * vColor.a);
        if (glassAlpha < 0.004) {
            discard;
        }
        albedoLinear = srgbToLinear(tex.rgb * vColor.rgb);
    }

    vec3 baseNormal = safeNormalize(vWorldNormal, vec3(0.0, 1.0, 0.0));
    if (!gl_FrontFacing) {
        baseNormal = -baseNormal;
    }

    float viewDist = length(vFeetPos);
    vec3 viewDir = vFeetPos / max(viewDist, 1e-4);

#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    LightingInputs lin;
    lin.albedoLinear = albedoLinear;
    lin.worldNormal = baseNormal;
    lin.feetPos = vFeetPos;
    lin.viewDir = viewDir;
    lin.skyLight = vLm.y;
    lin.blockLight = vLm.x;
    lin.shadowFactor = 1.0;
    lin.matId = MAT_DEFAULT;
    lin.handLightLevel = max(float(heldBlockLightValue), float(heldBlockLightValue2)) / 15.0;
    lin.nightVision = nightVision;

  #if defined(DIMENSION_NETHER)
    vec3 lit = shadeNetherOrEndSurface(lin, false);
    float fogT = clamp01(1.0 - exp(-viewDist * 0.018 * FOG_DENSITY));
    lit = mix(lit, srgbToLinear(fogColor) * 0.45 + vec3(0.08, 0.025, 0.012), fogT);
  #else
    vec3 lit = shadeNetherOrEndSurface(lin, true);
    float fogT = clamp01(1.0 - exp(-viewDist * 0.008 * FOG_DENSITY));
    lit = mix(lit, evalEndSky(viewDir, frameTimeCounter), fogT);
  #endif
    float alpha = (vIsWater > 0.5) ? 0.65 : glassAlpha;
    outColor0 = vec4(max(lit, vec3(0.0)), alpha);
#else
    AtmosphereState atmo = unpackAtmosphereVaryings(
        vAtmoZenith, vAtmoHorizon, vAtmoMie, vAtmoDirect,
        vAtmoAmbSky, vAtmoAmbGround, vAtmoSunDir, vAtmoShadowDir
    );
    mat4 shadowVP = mat4(vShadowC0, vShadowC1, vShadowC2, vShadowC3);

    float shadowFactor = sampleShadowMap(
        shadowtex0,
        shadowtex1,
        vFeetPos,
        baseNormal,
        dot(baseNormal, atmo.shadowLightDir),
        shadowVP,
        shadowDistance,
        float(shadowMapResolution),
        gl_FragCoord.xy,
        atmo.shadowFade,
        false
    );

    vec4 outRgba;
    float handLightLevel = max(float(heldBlockLightValue), float(heldBlockLightValue2)) / 15.0;
    if (vIsWater > 0.5) {
        // Compute water-only path distance (air distance from eye to surface is excluded)
        float waterPathDist;
        if (isEyeInWater == 1) {
            waterPathDist = viewDist;
        } else {
            float opaqueDepth = texelFetch(depthtex1, ivec2(gl_FragCoord.xy), 0).r;
            if (opaqueDepth >= 0.999999) {
                waterPathDist = 48.0;
            } else {
                float opaqueLinearZ = 1.0 / (vDepthCoeff.x * opaqueDepth + vDepthCoeff.y);
                waterPathDist = viewDist * max(opaqueLinearZ / max(vWaterLinearZ, 1e-4) - 1.0, 0.0);
            }
        }
        vec3 worldMod64 = getWorldPosMod64(vFeetPos, cameraPosition);
        outRgba = shadeOverworldWater(
            albedoLinear,
            worldMod64,
            baseNormal,
            vFeetPos,
            viewDir,
            viewDist,
            cameraPosition,
            vLm.y,
            vLm.x,
            shadowFactor,
            waterPathDist,
            (isEyeInWater == 1),
            handLightLevel,
            nightVision,
            atmo,
            frameTimeCounter
        );
    } else {
        // Stained glass, ice, slime, honey, portal: sharp Fresnel sky reflection + clean tint
        float alpha = glassAlpha;
        LightingInputs lin;
        lin.albedoLinear = albedoLinear;
        lin.worldNormal = baseNormal;
        lin.feetPos = vFeetPos;
        lin.viewDir = viewDir;
        lin.skyLight = vLm.y;
        lin.blockLight = vLm.x;
        lin.shadowFactor = shadowFactor;
        lin.matId = MAT_SPECULAR;
        lin.handLightLevel = handLightLevel;
        lin.nightVision = nightVision;

        vec3 glassLit = shadeOverworldSurface(lin, atmo);
        vec3 V = -viewDir;
        float fresnel = fresnelSchlick(clamp01(dot(baseNormal, V)), 0.04);
        vec3 reflDir = reflect(viewDir, baseNormal);
        reflDir.y = max(reflDir.y, 0.02);
        vec3 skyRefl = evalSkyGradient(reflDir, atmo) * (vLm.y * sqrt(max(vLm.y, 0.0)));

        outRgba = vec4(glassLit + (skyRefl * fresnel) / max(alpha, 0.06), alpha);
    }

    outRgba.rgb = applyOverworldMediumAndFog(
        outRgba.rgb, viewDir, vFeetPos, viewDist, far, atmo, cameraPosition.y,
        isEyeInWater, blindness, darknessFactor
    );
    outColor0 = vec4(max(outRgba.rgb, vec3(0.0)), outRgba.a);
#endif
}

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_WATER_PASS_GLSL
