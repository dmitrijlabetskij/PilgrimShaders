#ifndef LIB_NOISE_GLSL
#define LIB_NOISE_GLSL

// =============================================================================
// Pure-ALU Integer Hashes & Procedural Noise (Zero Texture Reads)
// Works identically in GLSL 330 and Vulkan GLSL 450.
// =============================================================================

uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float hash21(ivec2 p) {
    uint h = pcgHash(uint(p.x) * 374761393u + uint(p.y) * 668265263u);
    return float(h & 0x00FFFFFFu) * (1.0 / 16777216.0);
}

float hash31(ivec3 p) {
    uint h = pcgHash(uint(p.x) * 374761393u + uint(p.y) * 668265263u + uint(p.z) * 2147483647u);
    return float(h & 0x00FFFFFFu) * (1.0 / 16777216.0);
}

// Fast 2D bilinear value noise with cubic Hermite smoothing
float valueNoise2D(vec2 p) {
    vec2 i = floor(p);
    vec2 f = p - i;
    vec2 u = f * f * (3.0 - 2.0 * f);

    ivec2 ip = ivec2(i);
    float a = hash21(ip);
    float b = hash21(ip + ivec2(1, 0));
    float c = hash21(ip + ivec2(0, 1));
    float d = hash21(ip + ivec2(1, 1));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Anisotropic periodic 2D value noise + analytical gradient: vec3(val, ddx, ddz).
// Separate X/Z period masks wrap seamlessly on 64-block world coordinates.
vec3 valueNoise2DGradAniso(vec2 p, ivec2 periodMask, ivec2 seedOffset) {
    vec2 i = floor(p);
    vec2 f = p - i;
    vec2 u = f * f * (3.0 - 2.0 * f);
    vec2 du = 6.0 * f * (1.0 - f);

    ivec2 ip0 = ivec2(i);
    ivec2 p00 = (ip0 & periodMask) + seedOffset;
    ivec2 p10 = ((ip0 + ivec2(1, 0)) & periodMask) + seedOffset;
    ivec2 p01 = ((ip0 + ivec2(0, 1)) & periodMask) + seedOffset;
    ivec2 p11 = ((ip0 + ivec2(1, 1)) & periodMask) + seedOffset;

    float a = hash21(p00);
    float b = hash21(p10);
    float c = hash21(p01);
    float d = hash21(p11);

    float k1 = b - a;
    float k2 = c - a;
    float k3 = a - b - c + d;

    float val = a + k1 * u.x + k2 * u.y + k3 * u.x * u.y;
    vec2 grad = du * vec2(k1 + k3 * u.y, k2 + k3 * u.x);
    return vec3(val, grad);
}

// Fast 3-octave rotated FBM (nebula / general wispy noise, 0 texture reads)
float cloudFbm(vec2 p) {
    const mat2 rot = mat2(0.80, -0.60, 0.60, 0.80);
    float sum = 0.56 * valueNoise2D(p);
    p = rot * p * 2.08 + vec2(17.3, 9.1);
    sum += 0.29 * valueNoise2D(p);
    p = rot * p * 2.12 + vec2(11.7, 23.4);
    sum += 0.15 * valueNoise2D(p);
    return sum;
}

// Lightweight 2-octave cloud density used for cloud volume slices, self-shadowing & reflections
float cloudShapeShadow(vec2 p) {
    float macro = valueNoise2D(p * 0.42 + vec2(3.7, -5.2));
    float n0 = valueNoise2D(p);
    return clamp(n0 * 0.62 + macro * 0.38, 0.0, 1.0);
}

// Crisp 3-octave volumetric cloud slice density (smooth puff detail + macro banks)
float cloudShapeSlice(vec2 p) {
    const mat2 rot = mat2(0.80, -0.60, 0.60, 0.80);
    float macro = valueNoise2D(p * 0.40 + vec2(3.7, -5.2));
    float n0 = valueNoise2D(p);
    float n1 = valueNoise2D(rot * p * 2.15 + vec2(17.3, 9.1));
    return clamp(n0 * 0.48 + n1 * 0.20 + macro * 0.32, 0.0, 1.0);
}

#endif // LIB_NOISE_GLSL
