#ifndef LIB_SETTINGS_GLSL
#define LIB_SETTINGS_GLSL

// =============================================================================
// LumenLite Configuration & Material IDs (Iris / Vulkan-Aperture Portable)
// =============================================================================

// --- Shadow Settings ---
const int shadowMapResolution = 1024; // [512 1024 1536 2048]
const float shadowDistance = 64.0;    // [48.0 64.0 80.0 96.0 128.0 160.0]
const float sunPathRotation = -35.0;
const bool shadowHardwareFiltering = true;
const bool shadowtex0HardwareFiltering = true;

#define SHADOW_SAMPLES 1          // [1 2 4]
#define SHADOW_DISTORTION 0.82    // [0.50 0.65 0.75 0.82 0.85 0.90]

// --- Visual Features (Pure ALU / Zero-Extra-Pass) ---
#define CLOUDS_ENABLED
#define WAVE_ANIMATION
#define DYNAMIC_HANDLIGHT

// --- Color & Atmosphere ---
#define TONEMAP_MODE 0            // [0 1]  0 = AgX (Filmic), 1 = ACES (Vibrant)
#define EXPOSURE 1.00             // [0.75 0.90 1.00 1.15 1.30 1.45]
#define SATURATION 1.12           // [0.85 0.95 1.05 1.12 1.20 1.30]
#define CONTRAST 1.08             // [0.90 1.00 1.08 1.14 1.22]
#define FOG_DENSITY 0.85          // [0.00 0.45 0.70 0.85 1.20 1.60]

// --- Material Classification IDs (Packed in 3 bits: 0..7) ---
const int MAT_DEFAULT     = 0;
const int MAT_FOLIAGE     = 1;
const int MAT_EMISSIVE    = 2;
const int MAT_SPECULAR    = 3;
const int MAT_SKIN_ENTITY = 4;

// --- Block Properties IDs (Matching block.properties) ---
const int BLOCK_WATER           = 10001;
const int BLOCK_FOLIAGE_GROUND  = 10002;
const int BLOCK_FOLIAGE_CANOPY  = 10003;
const int BLOCK_EMISSIVE        = 10004;
const int BLOCK_SPECULAR        = 10005;
const int BLOCK_GLASS           = 10006;

#endif // LIB_SETTINGS_GLSL
