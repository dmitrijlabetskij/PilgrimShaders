#ifndef LIB_SHADOW_PASS_GLSL
#define LIB_SHADOW_PASS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/iris_compat.glsl"

#if defined(VERTEX_SHADER)

#include "/lib/shadows.glsl"

#ifdef SHADOW_SOLID

void main() {
#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
#else
    gl_Position = distortShadowClip(gl_ModelViewProjectionMatrix * gl_Vertex);
#endif
}

#else

#include "/lib/waving.glsl"

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform float rainStrength;

in vec4 mc_Entity;
in vec2 mc_midTexCoord;

out vec2 vUv;

void main() {
#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    vUv = vec2(0.0);
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    return;
#else
    int blockId = int(mc_Entity.x + 0.5);

    // Cull water from shadow map so sunlight reaches seafloor & no shadowtex1 copy is needed
    if (blockId == BLOCK_WATER) {
        vUv = vec2(0.0);
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        return;
    }

    vUv = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec4 shadowViewPos = gl_ModelViewMatrix * gl_Vertex;

  #ifdef WAVE_ANIMATION
    if (blockId == BLOCK_FOLIAGE_GROUND || blockId == BLOCK_FOLIAGE_CANOPY) {
        vec3 feetPos = (shadowModelViewInverse * shadowViewPos).xyz;
        vec3 worldMod64 = getWorldPosMod64(feetPos, cameraPosition);
        float isTop = clamp((mc_midTexCoord.y - gl_MultiTexCoord0.y) * 32.0, 0.0, 1.0);
        vec3 wave = calcWavingOffset(worldMod64, blockId, isTop, frameTimeCounter, rainStrength);
        shadowViewPos.xyz += mat3(shadowModelView) * wave;
    }
  #endif

    gl_Position = distortShadowClip(gl_ProjectionMatrix * shadowViewPos);
#endif
}

#endif // SHADOW_SOLID

#elif defined(FRAGMENT_SHADER)

#ifdef SHADOW_SOLID

// Pure depth-only solid pass: zero discard, zero texture fetch -> full Hi-Z / Early-Z!
void main() {
}

#else

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 vUv;

// Depth-only pass: no color outputs -> zero shadowcolor VRAM allocation or ROP traffic
void main() {
#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    discard;
#else
    if (alphaTestRef > 0.0 && texture(gtexture, vUv).a < alphaTestRef) {
        discard;
    }
#endif
}

#endif // SHADOW_SOLID

#endif // VERTEX_SHADER / FRAGMENT_SHADER
#endif // LIB_SHADOW_PASS_GLSL
