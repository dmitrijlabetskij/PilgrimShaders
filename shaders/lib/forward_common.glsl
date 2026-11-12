#ifndef LIB_FORWARD_COMMON_GLSL
#define LIB_FORWARD_COMMON_GLSL

// =============================================================================
// Shared Post-Deferred Forward Pass (Particles, Weather, Hand Translucent)
// Runs AFTER deferred.fsh so output must be forward-lit HDR + atmospheric fog.
// =============================================================================

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/shadows.glsl"
#include "/lib/lighting.glsl"
#include "/lib/iris_compat.glsl"

#if defined(VERTEX_SHADER)

uniform mat4 gbufferModelViewInverse;
#ifdef FORWARD_SHADOWS
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
#endif
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;
#ifdef FORWARD_VERTEX_LIT
uniform float nightVision;
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;
#endif

out vec2 vUv;
out vec2 vLm;
out vec4 vColor;
out vec3 vWorldNormal;
out vec3 vFeetPos;
#ifdef FORWARD_VERTEX_LIT
out vec3 vVertexLight;
#endif
flat out vec4 vAtmoZenith;
flat out vec4 vAtmoHorizon;
flat out vec4 vAtmoMie;
flat out vec4 vAtmoDirect;
flat out vec4 vAtmoAmbSky;
flat out vec3 vAtmoAmbGround;
flat out vec3 vAtmoSunDir;
flat out vec3 vAtmoShadowDir;
#ifdef FORWARD_SHADOWS
flat out vec4 vShadowC0;
flat out vec4 vShadowC1;
flat out vec4 vShadowC2;
flat out vec4 vShadowC3;
#endif

void main() {
    vUv = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vLm = remapLightmap((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy);
    vColor = gl_Color;

    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
    vFeetPos = (gbufferModelViewInverse * viewPos).xyz;

    vec3 viewNormal = safeNormalize(gl_NormalMatrix * gl_Normal, vec3(0.0, 1.0, 0.0));
    vWorldNormal = safeNormalize(mat3(gbufferModelViewInverse) * viewNormal, vec3(0.0, 1.0, 0.0));

    vec3 sunDir = viewDirToWorld(sunPosition, gbufferModelViewInverse);
    vec3 shadowDir = viewDirToWorld(shadowLightPosition, gbufferModelViewInverse);
    AtmosphereState atmo = buildAtmosphere(sunDir, shadowDir, rainStrength);
    packAtmosphereVaryings(atmo, vAtmoZenith, vAtmoHorizon, vAtmoMie, vAtmoDirect, vAtmoAmbSky);
    vAtmoAmbGround = atmo.ambientGroundColor;
    vAtmoSunDir    = atmo.sunDir;
    vAtmoShadowDir = atmo.shadowLightDir;
#ifdef FORWARD_SHADOWS
    mat4 shadowVP = shadowProjection * shadowModelView;
    vShadowC0 = shadowVP[0];
    vShadowC1 = shadowVP[1];
    vShadowC2 = shadowVP[2];
    vShadowC3 = shadowVP[3];
#endif

#ifdef FORWARD_VERTEX_LIT
    LightingInputs vlin;
    vlin.albedoLinear = vec3(1.0);
    vlin.worldNormal = vWorldNormal;
    vlin.feetPos = vFeetPos;
    vlin.viewDir = safeNormalize(vFeetPos, vec3(0.0, 0.0, -1.0));
    vlin.skyLight = vLm.y;
    vlin.blockLight = vLm.x;
    vlin.shadowFactor = 1.0;
    vlin.matId = MAT_DEFAULT;
    vlin.handLightLevel = max(float(heldBlockLightValue), float(heldBlockLightValue2)) / 15.0;
    vlin.nightVision = nightVision;
  #if defined(DIMENSION_NETHER)
    vVertexLight = shadeNetherOrEndSurface(vlin, false);
  #elif defined(DIMENSION_END)
    vVertexLight = shadeNetherOrEndSurface(vlin, true);
  #else
    vVertexLight = shadeOverworldSurface(vlin, atmo);
  #endif
#endif

    gl_Position = gl_ProjectionMatrix * viewPos;
}

#elif defined(FRAGMENT_SHADER)

uniform sampler2D gtexture;
#if defined(FORWARD_SHADOWS) && !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
uniform sampler2DShadow shadowtex0;
#endif
#ifdef GBUFFER_ENTITY
uniform vec4 entityColor;
#endif
uniform vec3 cameraPosition;
uniform vec3 fogColor;
uniform float frameTimeCounter;
uniform float far;
uniform float alphaTestRef;
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
#ifdef FORWARD_VERTEX_LIT
in vec3 vVertexLight;
#endif
flat in vec4 vAtmoZenith;
flat in vec4 vAtmoHorizon;
flat in vec4 vAtmoMie;
flat in vec4 vAtmoDirect;
flat in vec4 vAtmoAmbSky;
flat in vec3 vAtmoAmbGround;
flat in vec3 vAtmoSunDir;
flat in vec3 vAtmoShadowDir;
#ifdef FORWARD_SHADOWS
flat in vec4 vShadowC0;
flat in vec4 vShadowC1;
flat in vec4 vShadowC2;
flat in vec4 vShadowC3;
#endif

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor0;

void main() {
    vec4 tex = texture(gtexture, vUv);
    float alpha = tex.a * vColor.a;

#ifdef FORWARD_WEATHER
    if (alpha < 0.05) {
        discard;
    }
    alpha *= 0.55;
#else
    if (tex.a < alphaTestRef || alpha < 0.004) {
        discard;
    }
#endif

    vec3 albedoSrgb = tex.rgb * vColor.rgb;
#ifdef GBUFFER_ENTITY
    albedoSrgb = mix(albedoSrgb, entityColor.rgb, entityColor.a);
#endif
    vec3 albedoLinear = srgbToLinear(albedoSrgb);
    float viewDist = length(vFeetPos);
    vec3 viewDir = vFeetPos / max(viewDist, 1e-4);

#ifdef FORWARD_VERTEX_LIT
    vec3 lit = albedoLinear * vVertexLight;
    // Subtle self-glow for bright particles (flames/sparks/enchant)
    if (vLm.x > 0.85 && luminance(albedoLinear) > 0.35) {
        lit += albedoLinear * 1.1;
    }
  #if defined(DIMENSION_NETHER)
    float netherFog = 1.0 - exp(-viewDist * 0.018 * FOG_DENSITY);
    lit = mix(lit, srgbToLinear(fogColor) * 0.45 + vec3(0.08, 0.025, 0.012), clamp01(netherFog));
  #elif defined(DIMENSION_END)
    float endFog = 1.0 - exp(-viewDist * 0.008 * FOG_DENSITY);
    lit = mix(lit, vec3(0.03, 0.015, 0.06), clamp01(endFog));
  #else
    AtmosphereState atmo = unpackAtmosphereVaryings(
        vAtmoZenith, vAtmoHorizon, vAtmoMie, vAtmoDirect,
        vAtmoAmbSky, vAtmoAmbGround, vAtmoSunDir, vAtmoShadowDir
    );
    lit = applyOverworldMediumAndFog(
        lit, viewDir, vFeetPos, viewDist, far, atmo, cameraPosition.y,
        isEyeInWater, blindness, darknessFactor
    );
  #endif
#else
    LightingInputs lin;
    lin.albedoLinear = albedoLinear;
#ifdef FORWARD_WEATHER
    // Rain/snow drops have subtle vertical shading rather than harsh cube face normal
    lin.worldNormal = vec3(0.0, 1.0, 0.0);
#else
    vec3 n = safeNormalize(vWorldNormal, vec3(0.0, 1.0, 0.0));
    if (!gl_FrontFacing) {
        n = -n;
    }
    lin.worldNormal = n;
#endif
    lin.feetPos = vFeetPos;
    lin.viewDir = viewDir;
    lin.skyLight = vLm.y;
    lin.blockLight = vLm.x;
#ifdef GBUFFER_ENTITY
    lin.matId = MAT_SKIN_ENTITY;
#else
    lin.matId = MAT_DEFAULT;
#endif
    lin.handLightLevel = max(float(heldBlockLightValue), float(heldBlockLightValue2)) / 15.0;
    lin.nightVision = nightVision;

#if defined(DIMENSION_NETHER)
    lin.shadowFactor = 1.0;
    vec3 lit = shadeNetherOrEndSurface(lin, false);
    float netherFog = 1.0 - exp(-viewDist * 0.018 * FOG_DENSITY);
    lit = mix(lit, srgbToLinear(fogColor) * 0.45 + vec3(0.08, 0.025, 0.012), clamp01(netherFog));
#elif defined(DIMENSION_END)
    lin.shadowFactor = 1.0;
    vec3 lit = shadeNetherOrEndSurface(lin, true);
    float endFog = 1.0 - exp(-viewDist * 0.008 * FOG_DENSITY);
    lit = mix(lit, vec3(0.03, 0.015, 0.06), clamp01(endFog));
#else
    AtmosphereState atmo = unpackAtmosphereVaryings(
        vAtmoZenith, vAtmoHorizon, vAtmoMie, vAtmoDirect,
        vAtmoAmbSky, vAtmoAmbGround, vAtmoSunDir, vAtmoShadowDir
    );
  #ifdef FORWARD_WEATHER
    float skyVis = vLm.y * sqrt(max(vLm.y, 0.0));
    float skyLightMask = smoothstep(0.02, 0.28, vLm.y);
    vec3 weatherLight = atmo.ambientSkyColor * (skyVis * 1.35)
                      + atmo.directLightColor * (0.50 * skyLightMask)
                      + evalBlockLight(vLm.x)
                      + evalDynamicHandlight(vFeetPos, vec3(0.0, 1.0, 0.0), lin.handLightLevel)
                      + vec3(0.018, 0.022, 0.028) * (1.0 + nightVision * 10.0);
    vec3 lit = albedoLinear * weatherLight;
  #else
    #ifdef FORWARD_SHADOWS
    mat4 shadowVP = mat4(vShadowC0, vShadowC1, vShadowC2, vShadowC3);
    lin.shadowFactor = sampleShadowMap(
        shadowtex0,
        vFeetPos,
        lin.worldNormal,
        dot(lin.worldNormal, atmo.shadowLightDir),
        shadowVP,
        shadowDistance,
        float(shadowMapResolution),
        gl_FragCoord.xy,
        atmo.shadowFade,
        false
    );
    #else
    lin.shadowFactor = 1.0; // Skip shadow read on particles for speed
    #endif
    vec3 lit = shadeOverworldSurface(lin, atmo);

    // Subtle self-glow for bright particles (flames/sparks/enchant)
    if (vLm.x > 0.85 && luminance(albedoLinear) > 0.35) {
        lit += albedoLinear * 1.1;
    }
  #endif

    lit = applyOverworldMediumAndFog(
        lit, viewDir, vFeetPos, viewDist, far, atmo, cameraPosition.y,
        isEyeInWater, blindness, darknessFactor
    );
#endif
#endif // !FORWARD_VERTEX_LIT

#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    float blind = clamp01(max(blindness, darknessFactor));
    lit *= mix(1.0, exp(-viewDist * 0.18), blind);
#endif

    outColor0 = vec4(max(lit, vec3(0.0)), alpha);
}

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_FORWARD_COMMON_GLSL
