#ifndef LIB_DEFERRED_PASS_GLSL
#define LIB_DEFERRED_PASS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/packing.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/shadows.glsl"
#include "/lib/lighting.glsl"
#include "/lib/iris_compat.glsl"

#if defined(VERTEX_SHADER)

uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;

out vec3 vWorldRay;
flat out vec3 vCameraOffset;
flat out vec2 vDepthCoeff;
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
    vec4 clipPos = gl_ModelViewProjectionMatrix * gl_Vertex;
    vec2 ndcXY = clipPos.xy / clipPos.w;
    vec3 viewRay = vec3(
        ndcXY.x * gbufferProjectionInverse[0][0],
        ndcXY.y * gbufferProjectionInverse[1][1],
        -1.0
    );
    vWorldRay = mat3(gbufferModelViewInverse) * viewRay;
    vCameraOffset = gbufferModelViewInverse[3].xyz;
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

    gl_Position = clipPos;
}

#elif defined(FRAGMENT_SHADER)

/* const int colortex0Format = R11F_G11F_B10F; */
/* const int colortex1Format = RGBA8; */
const bool colortex0Clear = true;
const bool colortex1Clear = true;
const bool colortex0MipmapEnabled = false;
const bool colortex1MipmapEnabled = false;
const float shadowDistanceRenderMul = 1.0;
const float entityShadowDistanceMul = 0.25;

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D depthtex0;
#if !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
uniform sampler2DShadow shadowtex0;
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

in vec3 vWorldRay;
flat in vec3 vCameraOffset;
flat in vec2 vDepthCoeff;
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
    ivec2 texel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex0, texel, 0).r;

#if !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
    AtmosphereState atmo = unpackAtmosphereVaryings(
        vAtmoZenith, vAtmoHorizon, vAtmoMie, vAtmoDirect,
        vAtmoAmbSky, vAtmoAmbGround, vAtmoSunDir, vAtmoShadowDir
    );
#endif

    // Sky early-out: skips colortex0, colortex1, shadowtex0, and linearZ decode!
    if (depth >= 0.999999) {
        vec3 viewDir = normalize(vWorldRay);
        vec3 skyColor;
#if defined(DIMENSION_NETHER)
        skyColor = srgbToLinear(fogColor) * 0.45 + vec3(0.08, 0.025, 0.012);
#elif defined(DIMENSION_END)
        skyColor = evalEndSky(viewDir, frameTimeCounter);
#else
        if (isEyeInWater == 1) {
            skyColor = vec3(0.02, 0.14, 0.22) * (0.25 + 0.75 * atmo.dayFactor);
        } else if (isEyeInWater == 2) {
            skyColor = vec3(1.10, 0.28, 0.04);
        } else if (isEyeInWater == 3) {
            skyColor = vec3(0.65, 0.78, 0.90);
        } else {
            skyColor = evalOverworldSky(viewDir, cameraPosition, atmo, frameTimeCounter, true);
        }
#endif
        float blindSky = clamp01(max(blindness, darknessFactor));
        skyColor *= (1.0 - blindSky);
        // Micro-dither breaks 5-bit blue mantissa stepping in R11F_G11F_B10F sky gradients
        skyColor *= 1.0 + ignCentered(gl_FragCoord.xy) * (1.0 / 64.0);
        outColor0 = vec4(max(skyColor, vec3(0.0)), 1.0);
        return;
    }

    float linearZ = 1.0 / (vDepthCoeff.x * depth + vDepthCoeff.y);
    vec3 feetPos = vWorldRay * linearZ + vCameraOffset;
    float viewDist = length(feetPos);
    vec3 viewDir = feetPos / max(viewDist, 1e-4);

    // Read packed G-buffer (only 2 color reads!)
    vec3 albedoLinear = texelFetch(colortex0, texel, 0).rgb;
    vec4 gbuf1 = texelFetch(colortex1, texel, 0);

    vec3 worldNormal;
    float skyLight;
    float blockLight;
    int matId;
    unpackGbufferData(gbuf1, worldNormal, skyLight, blockLight, matId);

    LightingInputs lin;
    lin.albedoLinear = albedoLinear;
    lin.worldNormal = worldNormal;
    lin.feetPos = feetPos;
    lin.viewDir = viewDir;
    lin.skyLight = skyLight;
    lin.blockLight = blockLight;
    lin.matId = matId;
    lin.handLightLevel = max(float(heldBlockLightValue), float(heldBlockLightValue2)) / 15.0;
    lin.nightVision = nightVision;

#if defined(DIMENSION_NETHER)
    lin.shadowFactor = 1.0;
    vec3 lit = shadeNetherOrEndSurface(lin, false);
    float netherFog = clamp01(1.0 - exp(-viewDist * 0.018 * FOG_DENSITY));
    lit = mix(lit, srgbToLinear(fogColor) * 0.45 + vec3(0.08, 0.025, 0.012), netherFog);
#elif defined(DIMENSION_END)
    lin.shadowFactor = 1.0;
    vec3 lit = shadeNetherOrEndSurface(lin, true);
    float endFog = clamp01(1.0 - exp(-viewDist * 0.008 * FOG_DENSITY));
    lit = mix(lit, evalEndSky(viewDir, frameTimeCounter), endFog);
#else
    // Skip shadow sampling completely inside sealed caves (skyLight <= 0.02)
    if (skyLight <= 0.02) {
        lin.shadowFactor = 0.0;
    } else {
        mat4 shadowVP = mat4(vShadowC0, vShadowC1, vShadowC2, vShadowC3);
        float NdotL = dot(worldNormal, atmo.shadowLightDir);
        bool isFoliage = (matId == MAT_FOLIAGE);
        lin.shadowFactor = sampleShadowMap(
            shadowtex0,
            feetPos,
            worldNormal,
            NdotL,
            shadowVP,
            shadowDistance,
            float(shadowMapResolution),
            gl_FragCoord.xy,
            atmo.shadowFade,
            isFoliage
        );
    }

    vec3 lit = shadeOverworldSurface(lin, atmo);
    lit = applyOverworldMediumAndFog(
        lit, viewDir, feetPos, viewDist, far, atmo, cameraPosition.y,
        isEyeInWater, blindness, darknessFactor
    );
#endif

#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    float blind = clamp01(max(blindness, darknessFactor));
    lit *= mix(1.0, exp(-viewDist * 0.18), blind);
#endif

    lit *= 1.0 + ignCentered(gl_FragCoord.xy) * (1.0 / 64.0);
    outColor0 = vec4(max(lit, vec3(0.0)), 1.0);
}

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_DEFERRED_PASS_GLSL
