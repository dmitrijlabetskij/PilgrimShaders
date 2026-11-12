#!/usr/bin/env python3
"""Validate all Iris GLSL shaders and Vulkan GLSL 450 portability of /lib/*."""

from __future__ import annotations

import math
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHADERS_DIR = ROOT / "shaders"
INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"([^"]+)"\s*$')


def expand_includes(
    path: pathlib.Path,
    extra_defines: dict[str, str] | None = None,
    prepend_defines: list[str] | None = None,
) -> str:
    """Recursively expand Iris #include \"/...\" directives."""
    lines_out: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        m_inc = INCLUDE_RE.match(raw_line)
        if m_inc:
            inc_rel = m_inc.group(1).lstrip("/")
            inc_path = SHADERS_DIR / inc_rel
            if not inc_path.is_file():
                raise FileNotFoundError(f"Missing include {inc_rel} referenced from {path}")
            lines_out.append(expand_includes(inc_path, extra_defines))
            continue

        line = raw_line
        if extra_defines:
            for key, val in extra_defines.items():
                if line.lstrip().startswith(f"#define {key}"):
                    if val == "UNDEF":
                        line = f"// disabled for variant test: {key}"
                    else:
                        line = f"#define {key} {val}"
                    break
        lines_out.append(line)
        if prepend_defines and line.lstrip().startswith("#version"):
            for macro in prepend_defines:
                lines_out.append(f"#define {macro}")
    return "\n".join(lines_out) + "\n"


def run_glslang(source: str, stage: str, vulkan: bool, tmp_dir: pathlib.Path, label: str) -> None:
    ext = "frag" if stage == "frag" else "vert"
    tmp_file = tmp_dir / f"{label.replace('/', '_')}.{ext}"
    tmp_file.write_text(source, encoding="utf-8")

    cmd = ["glslangValidator", "-S", stage]
    if vulkan:
        spv_out = tmp_file.with_suffix(".spv")
        cmd.extend(["-V", "-o", str(spv_out)])
    cmd.append(str(tmp_file))

    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        print(f"[FAIL] {label} ({'Vulkan' if vulkan else 'Iris GLSL 330'})")
        print(res.stdout)
        print(res.stderr)
        sys.exit(1)


def validate_iris_shaders(tmp_dir: pathlib.Path) -> int:
    shader_files = sorted(
        list(SHADERS_DIR.rglob("*.vsh")) + list(SHADERS_DIR.rglob("*.fsh"))
    )
    if not shader_files:
        raise RuntimeError("No .vsh or .fsh files found in shaders/")

    for path in shader_files:
        rel = path.relative_to(ROOT).as_posix()
        stage = "vert" if path.suffix == ".vsh" else "frag"
        expanded = expand_includes(path)
        run_glslang(expanded, stage, vulkan=False, tmp_dir=tmp_dir, label=rel)

    # Also test key setting permutations on deferred & water passes
    variants = [
        {"SHADOW_SAMPLES": "1", "TONEMAP_MODE": "1"},
        {"SHADOW_SAMPLES": "2", "MC_RENDER_STAGE_ENTITIES": "12"},
        {"SHADOW_SAMPLES": "4", "CLOUDS_ENABLED": "UNDEF", "WAVE_ANIMATION": "UNDEF", "DYNAMIC_HANDLIGHT": "UNDEF", "GOD_RAYS": "UNDEF"},
    ]
    for idx, defs in enumerate(variants):
        for rel_name, stage in [
            ("deferred.fsh", "frag"),
            ("gbuffers_water.fsh", "frag"),
            ("gbuffers_entities_translucent.fsh", "frag"),
            ("gbuffers_terrain.vsh", "vert"),
            ("shadow.vsh", "vert"),
            ("shadow.fsh", "frag"),
            ("final.vsh", "vert"),
            ("final.fsh", "frag"),
        ]:
            p = SHADERS_DIR / rel_name
            expanded = expand_includes(p, extra_defines=defs)
            run_glslang(expanded, stage, vulkan=False, tmp_dir=tmp_dir, label=f"variant{idx}_{rel_name}")

    return len(shader_files)


def validate_vulkan_portability(tmp_dir: pathlib.Path) -> None:
    """Compile ALL core /lib/* algorithm modules directly to Vulkan SPIR-V (GLSL 450)."""
    harness = """#version 450
#extension GL_GOOGLE_include_directive : enable

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/packing.glsl"
#include "/lib/noise.glsl"
#include "/lib/waving.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/shadows.glsl"
#include "/lib/lighting.glsl"
#include "/lib/water.glsl"
#include "/lib/tonemap.glsl"

layout(set = 0, binding = 0) uniform sampler2DShadow uShadowTex;
layout(set = 0, binding = 2) uniform sampler2D uShadowDepthTex;
layout(set = 0, binding = 1) uniform FrameUBO {
    mat4 shadowView;
    mat4 shadowProj;
    vec3 sunDir;
    vec3 shadowDir;
    vec3 camPos;
    float timeSec;
    float rainStrength;
} ubo;

layout(location = 0) in vec3 inFeetPos;
layout(location = 1) in vec3 inNormal;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 wave = calcWavingOffset(inFeetPos, BLOCK_FOLIAGE_GROUND, 1.0, ubo.timeSec, ubo.rainStrength);
    vec4 packed = packGbufferData(inNormal, 0.9, 0.4, MAT_FOLIAGE, gl_FragCoord.xy);
    vec3 decN; float skyL; float blockL; int matId;
    unpackGbufferData(packed, decN, skyL, blockL, matId);

    AtmosphereState atmo = buildAtmosphere(ubo.sunDir, ubo.shadowDir, ubo.rainStrength);
    vec3 viewDir = normalize(inFeetPos + wave + vec3(0.0, 0.0, 1.0));
    float sh = sampleShadowMap(
        uShadowTex, uShadowDepthTex, inFeetPos, decN, dot(decN, atmo.shadowLightDir),
        ubo.shadowProj * ubo.shadowView, 96.0, 1024.0,
        gl_FragCoord.xy, atmo.shadowFade, matId == MAT_FOLIAGE
    );

    LightingInputs lin;
    lin.albedoLinear = srgbToLinear(vec3(0.4, 0.7, 0.3));
    lin.worldNormal = decN;
    lin.feetPos = inFeetPos;
    lin.viewDir = viewDir;
    lin.skyLight = skyL;
    lin.blockLight = blockL;
    lin.shadowFactor = sh;
    lin.matId = matId;
    lin.handLightLevel = 0.8;
    lin.nightVision = 0.0;

    vec3 lit = shadeOverworldSurface(lin, atmo);
    lit = applyOverworldMediumAndFog(lit, viewDir, inFeetPos, 32.0, 256.0, atmo, ubo.camPos.y, 0, 0.0, 0.0);
    vec4 water = shadeOverworldWater(
        vec3(0.1, 0.3, 0.4), inFeetPos, vec3(0.0, 1.0, 0.0), inFeetPos, viewDir, 32.0,
        ubo.camPos, skyL, blockL, sh, 3.0, false, 0.8, 0.0, atmo, ubo.timeSec
    );
    vec3 merged = mix(lit, water.rgb, water.a);
    outColor = vec4(applyGradingAndTonemap(merged, gl_FragCoord.xy), 1.0);
}
"""
    # Expand includes manually so glslangValidator resolves /lib/* cleanly
    lines: list[str] = []
    for line in harness.splitlines():
        m_inc = INCLUDE_RE.match(line)
        if m_inc:
            inc_path = SHADERS_DIR / m_inc.group(1).lstrip("/")
            lines.append(expand_includes(inc_path))
        elif "GL_GOOGLE_include_directive" in line:
            continue
        else:
            lines.append(line)
    expanded_vk = "\n".join(lines) + "\n"
    run_glslang(expanded_vk, "frag", vulkan=True, tmp_dir=tmp_dir, label="vulkan_core_lib_test")


def verify_packing_math() -> None:
    """Verify bit-exact 8-bit RGBA8 octahedral normal and blockLight/matId packing."""
    def quantize_u8(v: float) -> float:
        return round(min(max(v, 0.0), 1.0) * 255.0) / 255.0

    def oct_encode(nx: float, ny: float, nz: float) -> tuple[float, float]:
        l1 = abs(nx) + abs(ny) + abs(nz)
        nx, ny, nz = nx / l1, ny / l1, nz / l1
        if nz < 0.0:
            sx = 1.0 if nx >= 0.0 else -1.0
            sy = 1.0 if ny >= 0.0 else -1.0
            nx, ny = (1.0 - abs(ny)) * sx, (1.0 - abs(nx)) * sy
        return ((nx * 0.5 + 0.5) * (254.0 / 255.0), (ny * 0.5 + 0.5) * (254.0 / 255.0))

    def oct_decode(ex: float, ey: float) -> tuple[float, float, float]:
        ex = min(max(ex * (255.0 / 254.0), 0.0), 1.0) * 2.0 - 1.0
        ey = min(max(ey * (255.0 / 254.0), 0.0), 1.0) * 2.0 - 1.0
        nz = 1.0 - abs(ex) - abs(ey)
        if nz < 0.0:
            sx = 1.0 if ex >= 0.0 else -1.0
            sy = 1.0 if ey >= 0.0 else -1.0
            ex, ey = (1.0 - abs(ey)) * sx, (1.0 - abs(ex)) * sy
        inv_len = 1.0 / math.sqrt(ex * ex + ey * ey + nz * nz)
        return (ex * inv_len, ey * inv_len, nz * inv_len)

    axis_normals = [
        (1.0, 0.0, 0.0), (-1.0, 0.0, 0.0),
        (0.0, 1.0, 0.0), (0.0, -1.0, 0.0),
        (0.0, 0.0, 1.0), (0.0, 0.0, -1.0),
    ]
    for nx, ny, nz in axis_normals:
        ex, ey = oct_encode(nx, ny, nz)
        dx, dy, dz = oct_decode(quantize_u8(ex), quantize_u8(ey))
        err = math.sqrt((dx - nx) ** 2 + (dy - ny) ** 2 + (dz - nz) ** 2)
        assert err < 1e-6, f"Axis normal {(nx, ny, nz)} not exact: {(dx, dy, dz)}"

    for mat_id in range(8):
        for level in range(16):
            bl = level / 15.0
            bl_q = min(max(math.floor(math.sqrt(bl) * 31.0 + 0.5), 0.0), 31.0)
            packed = quantize_u8((bl_q * 8.0 + mat_id) / 255.0)
            packed_int = int(round(packed * 255.0))
            assert (packed_int & 7) == mat_id
            assert abs(((packed_int >> 3) / 31.0) ** 2 - bl) < 0.04


def main() -> None:
    verify_packing_math()
    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = pathlib.Path(tmp)
        count = validate_iris_shaders(tmp_dir)
        validate_vulkan_portability(tmp_dir)
        print(f"[OK] Validated {count} Iris shader files (+ option variants), RGBA8 packing math, and Vulkan GLSL 450 SPIR-V core (/lib/*).")


if __name__ == "__main__":
    main()
