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

out vec2 vUv;
out vec2 vLm;
out vec4 vColor;
out vec3 vWorldNormal;
out vec3 vFeetPos;
flat out vec3 vSunDir;
flat out vec3 vShadowDir;
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

    vSunDir = viewDirToWorld(sunPosition, gbufferModelViewInverse);
    vShadowDir = viewDirToWorld(shadowLightPosition, gbufferModelViewInverse);
#ifdef FORWARD_SHADOWS
    mat4 shadowVP = shadowProjection * shadowModelView;
    vShadowC0 = shadowVP[0];
    vShadowC1 = shadowVP[1];
    vShadowC2 = shadowVP[2];
    vShadowC3 = shadowVP[3];
#endif

    gl_Position = gl_ProjectionMatrix * viewPos;
}

#elif defined(FRAGMENT_SHADER)

uniform sampler2D gtexture;
#ifdef FORWARD_SHADOWS
uniform sampler2DShadow shadowtex0;
#endif
#ifdef GBUFFER_ENTITY
uniform vec4 entityColor;
#endif
uniform vec3 cameraPosition;
uniform vec3 fogColor;
uniform float rainStrength;
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
flat in vec3 vSunDir;
flat in vec3 vShadowDir;
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
    AtmosphereState atmo = buildAtmosphere(vSunDir, vShadowDir, rainStrength);
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
    lin.shadowFactor = 1.0; // Skip shadow read on particles/weather for speed
  #endif
    vec3 lit = shadeOverworldSurface(lin, atmo);

    // Subtle self-glow for bright particles (flames/sparks/enchant)
    if (vLm.x > 0.85 && luminance(albedoLinear) > 0.35) {
        lit += albedoLinear * 1.1;
    }

    lit = applyOverworldMediumAndFog(
        lit, viewDir, vFeetPos, viewDist, far, atmo, cameraPosition.y,
        isEyeInWater, blindness, darknessFactor
    );
#endif

#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    float blind = clamp01(max(blindness, darknessFactor));
    lit *= mix(1.0, exp(-viewDist * 0.18), blind);
#endif

    outColor0 = vec4(max(lit, vec3(0.0)), alpha);
}

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_FORWARD_COMMON_GLSL
