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

// Fast 2-octave rotated FBM for clouds (~16 ALU ops, 0 texture reads)
float cloudFbm(vec2 p) {
    const mat2 rot = mat2(0.80, -0.60, 0.60, 0.80);
    float sum = 0.68 * valueNoise2D(p);
    p = rot * p * 2.13 + vec2(17.3, 9.1);
    sum += 0.32 * valueNoise2D(p);
    return sum;
}

// Single-grid directional travelling Gaussian wavelet bump (returns vec3(height, dH/dx, dH/dz)).
// Smoothly fades in, travels along windDir, and fades out; zero rings, zero cell boundary seams.
vec3 evalDirectionalWaveletGrid(
    vec2 worldXZMod64,
    float scale,
    int periodMask,
    float timeSec,
    float speed,
    float rainStrength,
    vec2 gridShift,
    int seedOffset,
    float timeOffset
) {
    const vec2 WIND_DIR  = vec2(0.920726, 0.390211); // normalize(vec2(0.92, 0.39))
    const vec2 WIND_PERP = vec2(-0.390211, 0.920726);

    vec2 p = worldXZMod64 * scale + gridShift;
    ivec2 cell = ivec2(floor(p)) & periodMask;
    vec2 local = fract(p) - 0.5;

    float cellPhase = hash21(cell + ivec2(seedOffset, seedOffset * 3)) * 16.0;
    float cycle = timeSec * speed + cellPhase + timeOffset;
    int epoch = int(floor(cycle)) & 1023;
    float life = fract(cycle);

    ivec2 seed = cell + ivec2(epoch * 37 + seedOffset, epoch * 91 + seedOffset * 2);
    float spawnThresh = 0.70 - 0.45 * rainStrength;
    if (hash21(seed) <= spawnThresh) {
        return vec3(0.0);
    }

    vec2 startPos = (vec2(hash21(seed + ivec2(13, 7)), hash21(seed + ivec2(29, 43))) - 0.5) * 0.08;
    vec2 center = startPos + WIND_DIR * ((life - 0.5) * 0.32);
    vec2 delta = local - center;

    float along  = dot(delta, WIND_DIR);
    float across = dot(delta, WIND_PERP);
    float q = along * along * 52.0 + across * across * 24.0;
    if (q > 8.0) {
        return vec3(0.0);
    }

    float h = exp(-q);
    float fade = sin(life * 3.14159265);
    fade *= fade;

    float edgeDist = max(abs(local.x), abs(local.y));
    float edgeFade = smoothstep(0.49, 0.26, edgeDist);
    float amp = fade * edgeFade;

    float dHa = -104.0 * along  * h * amp * scale;
    float dHc = -48.0  * across * h * amp * scale;
    vec2 grad = dHa * WIND_DIR + dHc * WIND_PERP;
    return vec3(h * amp, grad);
}

#endif // LIB_NOISE_GLSL
