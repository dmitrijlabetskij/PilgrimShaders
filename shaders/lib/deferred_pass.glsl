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
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;

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
    vec3 sunDir = viewDirToWorld(sunPosition, gbufferModelViewInverse);
    vec3 shadowDir = viewDirToWorld(shadowLightPosition, gbufferModelViewInverse);
    AtmosphereState atmo = buildAtmosphere(sunDir, shadowDir, rainStrength);

    vAtmoZenith    = vec4(atmo.zenithColor, atmo.dayFactor);
    vAtmoHorizon   = vec4(atmo.horizonColor, atmo.sunsetFactor);
    vAtmoMie       = vec4(atmo.mieColor, atmo.nightFactor);
    vAtmoDirect    = vec4(atmo.directLightColor, atmo.shadowFade);
    vAtmoAmbSky    = vec4(atmo.ambientSkyColor, atmo.rainStrength);
    vAtmoAmbGround = atmo.ambientGroundColor;
    vAtmoSunDir    = atmo.sunDir;
    vAtmoShadowDir = atmo.shadowLightDir;

    mat4 shadowVP = shadowProjection * shadowModelView;
    vShadowC0 = shadowVP[0];
    vShadowC1 = shadowVP[1];
    vShadowC2 = shadowVP[2];
    vShadowC3 = shadowVP[3];

    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}

#elif defined(FRAGMENT_SHADER)

/* const int colortex0Format = R11F_G11F_B10F; */
/* const int colortex1Format = RGBA8; */
const bool colortex0Clear = true;
const bool colortex1Clear = true;
const bool colortex0MipmapEnabled = false;
const bool colortex1MipmapEnabled = false;
const float shadowDistanceRenderMul = 1.0;
const float entityShadowDistanceMul = 0.30;

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D depthtex0;
uniform sampler2DShadow shadowtex0;

uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;

uniform vec3 cameraPosition;
uniform vec3 fogColor;
uniform float frameTimeCounter;
uniform float far;
uniform float viewWidth;
uniform float viewHeight;
uniform float nightVision;
uniform float blindness;
uniform float darknessFactor;
uniform int isEyeInWater;
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

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
    vec2 screenUV = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texelFetch(depthtex0, texel, 0).r;

#if !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
    AtmosphereState atmo;
    atmo.sunDir = vAtmoSunDir;
    atmo.moonDir = -vAtmoSunDir;
    atmo.shadowLightDir = vAtmoShadowDir;
    atmo.dayFactor = vAtmoZenith.a;
    atmo.sunsetFactor = vAtmoHorizon.a;
    atmo.nightFactor = vAtmoMie.a;
    atmo.rainStrength = vAtmoAmbSky.a;
    atmo.shadowFade = vAtmoDirect.a;
    atmo.zenithColor = vAtmoZenith.rgb;
    atmo.horizonColor = vAtmoHorizon.rgb;
    atmo.mieColor = vAtmoMie.rgb;
    atmo.directLightColor = vAtmoDirect.rgb;
    atmo.ambientSkyColor = vAtmoAmbSky.rgb;
    atmo.ambientGroundColor = vAtmoAmbGround;
#endif

    // Sky early-out: skips colortex0, colortex1, shadowtex0, and full feetPos projection!
    if (depth >= 0.999999) {
        vec4 farView = gbufferProjectionInverse * vec4(screenUV * 2.0 - 1.0, 1.0, 1.0);
        vec3 viewDir = normalize(mat3(gbufferModelViewInverse) * (farView.xyz / farView.w));
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

    vec3 viewPos = reconstructViewPos(screenUV, depth, gbufferProjectionInverse);
    vec3 feetPos = viewToFeetPos(viewPos, gbufferModelViewInverse);
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
