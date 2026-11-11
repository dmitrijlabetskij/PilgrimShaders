#ifndef LIB_GBUFFER_COMMON_GLSL
#define LIB_GBUFFER_COMMON_GLSL

// =============================================================================
// Shared Opaque G-Buffer Pass Logic (Vertex & Fragment)
// Used by gbuffers_terrain, gbuffers_entities, gbuffers_block, gbuffers_hand,
// gbuffers_damagedblock, gbuffers_basic, gbuffers_line, gbuffers_spidereyes, etc.
// =============================================================================

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/packing.glsl"
#include "/lib/iris_compat.glsl"

#if defined(VERTEX_SHADER)

#include "/lib/waving.glsl"

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform float rainStrength;

#ifdef USE_MC_ENTITY
in vec4 mc_Entity;
in vec2 mc_midTexCoord;
#endif

out vec2 vUv;
out vec2 vLm;
out vec4 vColor;
out vec3 vWorldNormal;
flat out int vMatId;

void main() {
    vUv = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vLm = remapLightmap((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy);
    vColor = gl_Color;

    // Terrain chunk normals are already in world space; entities/hand need view->world transform
#ifdef GBUFFER_TERRAIN
    vec3 worldNormal = safeNormalize(gl_Normal, vec3(0.0, 1.0, 0.0));
#else
    vec3 viewNormal = safeNormalize(gl_NormalMatrix * gl_Normal, vec3(0.0, 1.0, 0.0));
    vec3 worldNormal = safeNormalize(mat3(gbufferModelViewInverse) * viewNormal, vec3(0.0, 1.0, 0.0));
#endif

    int blockId = 0;
    int matId = MAT_DEFAULT;

#ifdef GBUFFER_ENTITY
    matId = MAT_SKIN_ENTITY;
#endif
#ifdef GBUFFER_EMISSIVE
    matId = MAT_EMISSIVE;
#endif

#ifdef USE_MC_ENTITY
    blockId = int(mc_Entity.x + 0.5);
    if (blockId == BLOCK_FOLIAGE_GROUND || blockId == BLOCK_FOLIAGE_CANOPY) {
        matId = MAT_FOLIAGE;
    } else if (blockId == BLOCK_EMISSIVE) {
        matId = MAT_EMISSIVE;
    } else if (blockId == BLOCK_SPECULAR) {
        matId = MAT_SPECULAR;
    }

    // Flatten crossed-quad normals on grass/flowers so they match ground lighting seamlessly
    if (blockId == BLOCK_FOLIAGE_GROUND) {
        worldNormal = normalize(mix(worldNormal, vec3(0.0, 1.0, 0.0), 0.78));
    }
#endif

    vWorldNormal = worldNormal;
    vMatId = matId;

    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;

#if defined(USE_MC_ENTITY) && defined(WAVE_ANIMATION) && !defined(NO_WAVING)
    if (blockId == BLOCK_FOLIAGE_GROUND || blockId == BLOCK_FOLIAGE_CANOPY) {
        vec3 feetPos = (gbufferModelViewInverse * viewPos).xyz;
        vec3 worldMod64 = getWorldPosMod64(feetPos, cameraPosition);
        // Minecraft atlas V runs top (0) -> bottom (1), so UV.y < midTexCoord.y is top half
        float isTop = clamp((mc_midTexCoord.y - gl_MultiTexCoord0.y) * 32.0, 0.0, 1.0);
        vec3 wave = calcWavingOffset(worldMod64, blockId, isTop, frameTimeCounter, rainStrength);
        viewPos.xyz += mat3(gbufferModelView) * wave;
    }
#endif

    gl_Position = gl_ProjectionMatrix * viewPos;
}

#elif defined(FRAGMENT_SHADER)

uniform sampler2D gtexture;
uniform float alphaTestRef;
#ifdef GBUFFER_ENTITY
uniform vec4 entityColor;
#endif

in vec2 vUv;
in vec2 vLm;
in vec4 vColor;
in vec3 vWorldNormal;
flat in int vMatId;

#ifdef GBUFFER_COLOR_ONLY
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor0;
#else
/* RENDERTARGETS: 0,1 */
layout(location = 0) out vec4 outColor0;
layout(location = 1) out vec4 outColor1;
#endif

void main() {
#ifdef NO_TEXTURE
    vec4 tex = vec4(1.0);
#else
    vec4 tex = texture(gtexture, vUv);
#endif

#ifndef NO_ALPHA_TEST
    if (tex.a < alphaTestRef) {
        discard;
    }
#endif

    vec3 albedoSrgb = tex.rgb * vColor.rgb;

#ifdef GBUFFER_TERRAIN
    // separateAo=true puts vanilla smooth-lighting AO in vColor.a on terrain
    float ao = mix(1.0, clamp01(vColor.a), 0.78);
    albedoSrgb *= ao;
#endif

#ifdef GBUFFER_ENTITY
    // Hit flash (red) & creeper swell flash (white)
    albedoSrgb = mix(albedoSrgb, entityColor.rgb, entityColor.a);
#endif

#ifdef GBUFFER_RAW_ALBEDO
    vec3 albedoLinear = albedoSrgb;
#else
    vec3 albedoLinear = srgbToLinear(albedoSrgb);
#endif

#ifdef GBUFFER_COLOR_ONLY
  #ifdef GBUFFER_EYES_BOOST
    albedoLinear *= 5.0;
  #endif
    outColor0 = vec4(max(albedoLinear, vec3(0.0)), clamp01(tex.a * vColor.a));
#else
    vec3 n = safeNormalize(vWorldNormal, vec3(0.0, 1.0, 0.0));
    if (!gl_FrontFacing) {
        n = -n;
    }

    float blockLight = vLm.x;
    float skyLight   = vLm.y;
    int matId        = vMatId;

  #ifdef GBUFFER_EMISSIVE
    blockLight = 1.0;
  #endif

    // Write only 8 bytes/pixel total: R11F_G11F_B10F (4B) + RGBA8 (4B)
#ifdef GBUFFER_ENTITY
    outColor0 = vec4(max(albedoLinear, vec3(0.0)), clamp01(tex.a * vColor.a));
#else
    outColor0 = vec4(max(albedoLinear, vec3(0.0)), 1.0);
#endif
    outColor1 = packGbufferData(n, skyLight, blockLight, matId, gl_FragCoord.xy);
#endif
}

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_GBUFFER_COMMON_GLSL
