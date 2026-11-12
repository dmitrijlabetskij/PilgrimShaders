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

in vec4 mc_Entity;

out vec2 vUv;

void main() {
#if defined(DIMENSION_NETHER) || defined(DIMENSION_END)
    vUv = vec2(0.0);
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    return;
#else
    int blockId = int(mc_Entity.x + 0.5);

    // Cull water from shadow pass so sunlight reaches seafloor & no shadowtex1 copy is needed.
    // Foliage stays steady in shadow pass so thin cutouts don't crawl across shadow texels.
    if (blockId == BLOCK_WATER) {
        vUv = vec2(0.0);
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        return;
    }

    // Canopy leaves remain steady in shadow pass so 1-pixel alpha cutouts don't crawl across texels
    vUv = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    gl_Position = distortShadowClip(gl_ModelViewProjectionMatrix * gl_Vertex);
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
