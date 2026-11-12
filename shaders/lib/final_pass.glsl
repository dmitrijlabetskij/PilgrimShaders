#ifndef LIB_FINAL_PASS_GLSL
#define LIB_FINAL_PASS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/noise.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/tonemap.glsl"
#include "/lib/iris_compat.glsl"

#if defined(VERTEX_SHADER)

#if defined(GOD_RAYS) && !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;

out vec2 vScreenUV;
out vec3 vWorldRay;
flat out vec2 vDepthCoeff;
flat out vec2 vSunScreenUV;
flat out float vSunScreenValid;
flat out vec3 vSunDir;
flat out vec3 vDirectColor;
flat out vec3 vMieColor;
flat out float vRainStrength;
#endif

void main() {
    vec4 clipPos = gl_ModelViewProjectionMatrix * gl_Vertex;
#if defined(GOD_RAYS) && !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
    vec2 ndcXY = clipPos.xy / clipPos.w;
    vScreenUV = ndcXY * 0.5 + 0.5;
    vec3 viewRay = vec3(
        ndcXY.x * gbufferProjectionInverse[0][0],
        ndcXY.y * gbufferProjectionInverse[1][1],
        -1.0
    );
    vWorldRay = mat3(gbufferModelViewInverse) * viewRay;
    vDepthCoeff = vec2(
        2.0 * gbufferProjectionInverse[2][3],
        gbufferProjectionInverse[3][3] - gbufferProjectionInverse[2][3]
    );

    vec3 sunDir = viewDirToWorld(sunPosition, gbufferModelViewInverse);
    vec3 shadowDir = viewDirToWorld(shadowLightPosition, gbufferModelViewInverse);
    AtmosphereState atmo = buildAtmosphere(sunDir, shadowDir, rainStrength);
    vSunDir       = atmo.sunDir;
    vDirectColor  = atmo.directLightColor;
    vMieColor     = atmo.mieColor;
    vRainStrength = atmo.rainStrength;

    // Project view-space sun position once per vertex (4 quad vertices) for screen-space god rays
    vec3 sunView = safeNormalize(sunPosition, vec3(0.0, 1.0, 0.0)) * 100.0;
    vec4 sunClip = gbufferProjection * vec4(sunView, 1.0);
    vSunScreenValid = (sunClip.w > 0.08) ? 1.0 : 0.0;
    vSunScreenUV = (sunClip.xy / max(sunClip.w, 0.08)) * 0.5 + 0.5;
#endif
    gl_Position = clipPos;
}

#elif defined(FRAGMENT_SHADER)

uniform sampler2D colortex0;
#if defined(GOD_RAYS) && !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;

uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform float blindness;
uniform float darknessFactor;
uniform int isEyeInWater;

in vec2 vScreenUV;
in vec3 vWorldRay;
flat in vec2 vDepthCoeff;
flat in vec2 vSunScreenUV;
flat in float vSunScreenValid;
flat in vec3 vSunDir;
flat in vec3 vDirectColor;
flat in vec3 vMieColor;
flat in float vRainStrength;

float rayDistanceFromDepth(float depth, float rayLenWorld) {
    if (depth >= 0.999999) {
        return 1e5;
    }
    return rayLenWorld / (vDepthCoeff.x * depth + vDepthCoeff.y);
}

// 3D volumetric underwater shafts: projects points along viewDir up through
// Snell-refracted water waves (avoids polar radial wheel stripes).
float evalUnderwaterColumns(vec3 viewDir, float maxDist, float jitter) {
    float marchLimit = min(maxDist, 30.0);
    if (marchLimit <= 2.2) {
        return 0.0;
    }

    // Snell refraction in water (IOR 1.333 => n_air/n_water = 0.75)
    float sinAir2 = max(1.0 - vSunDir.y * vSunDir.y, 0.0);
    float cosWater = sqrt(max(1.0 - 0.5625 * sinAir2, 0.4375));
    vec2 sunSlope = (vSunDir.xz * 0.75) / cosWater;

    const int STEPS = 5;
    float invSteps = 1.0 / float(STEPS);
    float beamSum = 0.0;
    float weightSum = 0.0;

    for (int i = 0; i < STEPS; ++i) {
        float t = (float(i) + jitter) * invSteps;
        float d = 1.8 + t * t * 28.2;
        if (d >= marchLimit) {
            break;
        }
        vec3 sampleWorld = cameraPosition + viewDir * d;
        vec2 waveUV = (sampleWorld.xz - sampleWorld.y * sunSlope) * 0.22;

        float n1 = valueNoise2D(waveUV + vec2(frameTimeCounter * 0.14, frameTimeCounter * 0.08));
        float n2 = valueNoise2D(waveUV * 1.9 + vec2(-frameTimeCounter * 0.10, frameTimeCounter * 0.13));
        float column = smoothstep(0.42, 0.84, n1 * 0.65 + n2 * 0.35);

        float stepFade = smoothstep(1.8, 5.5, d) * (1.0 - t) * clamp01((marchLimit - d) * 0.25);
        beamSum += column * stepFade;
        weightSum += stepFade;
    }

    return beamSum / max(weightSum, 0.25);
}

float evalScreenOcclusionShafts(bool underwater, float maxSpan, float jitter) {
    const int GOD_RAY_STEPS = 8;
    vec2 rayToSun = vSunScreenUV - vScreenUV;
    float rayLen = length(rayToSun);
    vec2 stepUV = rayToSun * (min(rayLen, maxSpan) / max(rayLen, 1e-4)) / float(GOD_RAY_STEPS);

    float accum = 0.0;
    float weightSum = 0.0;
    float decay = 1.0;

    for (int i = 0; i < GOD_RAY_STEPS; ++i) {
        vec2 sampleUV = clamp(vScreenUV + stepUV * (float(i) + jitter), vec2(0.001), vec2(0.999));
        float d = underwater
            ? textureLod(depthtex1, sampleUV, 0.0).r
            : textureLod(depthtex0, sampleUV, 0.0).r;
        accum += step(0.999999, d) * decay;
        weightSum += decay;
        decay *= 0.80;
    }

    return accum / max(weightSum, 1e-4);
}

vec3 evalScreenSpaceGodRays(vec3 viewDir, ivec2 texel) {
    if (isEyeInWater > 1) {
        return vec3(0.0);
    }

    float sunVis = smoothstep(-0.04, 0.14, vSunDir.y)
                 * (1.0 - 0.85 * vRainStrength)
                 * (1.0 - clamp01(max(blindness, darknessFactor)));
    if (sunVis <= 0.001) {
        return vec3(0.0);
    }

    float sunDot = dot(viewDir, vSunDir);
    bool underwater = (isEyeInWater == 1);
    float minDot = underwater ? -0.15 : 0.18;
    if (sunDot <= minDot) {
        return vec3(0.0);
    }

    float jitter = ign(gl_FragCoord.xy);
    float rayLenWorld = length(vWorldRay);

    if (underwater) {
        float opaqueDist = rayDistanceFromDepth(texelFetch(depthtex1, texel, 0).r, rayLenWorld);
        float surfDist   = rayDistanceFromDepth(texelFetch(depthtex0, texel, 0).r, rayLenWorld);
        float distMask   = smoothstep(0.8, 10.0, opaqueDist);
        if (distMask <= 0.001) {
            return vec3(0.0);
        }

        // Clamping by surfDist keeps 3D wave shafts strictly underneath the water surface
        float columns = evalUnderwaterColumns(viewDir, min(opaqueDist, surfDist), jitter);
        float shadowMask = 1.0;
        if (vSunScreenValid > 0.5 && sunDot > 0.18) {
            float shafts = evalScreenOcclusionShafts(true, 0.44, jitter);
            shadowMask = mix(0.32, 1.0, shafts);
        }

        float halo = smoothstep(0.05, 0.90, sunDot);
        halo *= halo;
        float shaftWeight = columns * smoothstep(-0.15, 0.55, sunDot);

        vec3 uwTint = vDirectColor * vec3(0.085, 0.34, 0.48);
        return uwTint * ((halo * 0.42 + shaftWeight * 0.68) * 0.24 * shadowMask * sunVis * distMask);
    }

    if (vSunScreenValid <= 0.5) {
        return vec3(0.0);
    }

    float viewDist = rayDistanceFromDepth(texelFetch(depthtex0, texel, 0).r, rayLenWorld);
    float distMask = smoothstep(1.5, 20.0, viewDist);
    if (distMask <= 0.001) {
        return vec3(0.0);
    }

    float cone = smoothstep(0.18, 0.82, sunDot);
    cone *= cone;
    float shafts = evalScreenOcclusionShafts(false, 0.54, jitter);

    float golden = 1.0 - smoothstep(0.08, 0.45, max(vSunDir.y, 0.0));
    vec3 airTint = mix(
        vDirectColor * vec3(1.0, 0.96, 0.88),
        vMieColor * 1.15 + vDirectColor * 0.35,
        0.45 + 0.35 * golden
    );
    return airTint * (0.068 * cone * shafts * sunVis * distMask);
}
#endif

layout(location = 0) out vec4 outColor;

void main() {
    // Pure single-fetch tonemapper when outside the sun cone, or at night / Nether / End
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec3 hdrColor = texelFetch(colortex0, texel, 0).rgb;
#if defined(GOD_RAYS) && !defined(DIMENSION_NETHER) && !defined(DIMENSION_END)
    hdrColor += evalScreenSpaceGodRays(normalize(vWorldRay), texel);
#endif
    vec3 finalSrgb = applyGradingAndTonemap(hdrColor, gl_FragCoord.xy);
    outColor = vec4(finalSrgb, 1.0);
}

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_FINAL_PASS_GLSL
