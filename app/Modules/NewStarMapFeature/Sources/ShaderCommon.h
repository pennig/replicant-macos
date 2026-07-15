#pragma once

#include <metal_stdlib>
#include "../CShaderTypes/include/ShaderTypes.h"
using namespace metal;

// ---------------------------------------------------------------------------
// Shared shader toolkit — helpers and constants used across more than one of the
// split shader files (StarField / Orrery / Overlays). Each .metal file is its own
// translation unit and `static` symbols don't cross that boundary (which is why the
// FlarePlayground shader has to keep its own copy of the noise), so anything used by
// two passes lives here and is #included per file. Everything is `static inline` /
// program-scope `constant`, so each including file gets its own internal copy — no
// cross-file link collision, and unused helpers don't warn.
// ---------------------------------------------------------------------------

// Two triangles → a quad, expressed as corner offsets.
constant float2 kCorners[6] = {
    float2(-1, -1), float2( 1, -1), float2(-1,  1),
    float2(-1,  1), float2( 1, -1), float2( 1,  1)
};

// Cheap 3D value noise for stellar granulation.
static inline float hash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 31.32);
    return fract((p.x + p.y) * p.z);
}
static inline float vnoise(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float c000 = hash13(i + float3(0,0,0)), c100 = hash13(i + float3(1,0,0));
    float c010 = hash13(i + float3(0,1,0)), c110 = hash13(i + float3(1,1,0));
    float c001 = hash13(i + float3(0,0,1)), c101 = hash13(i + float3(1,0,1));
    float c011 = hash13(i + float3(0,1,1)), c111 = hash13(i + float3(1,1,1));
    float y0 = mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y);
    float y1 = mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y);
    return mix(y0, y1, f.z);
}
static inline float fbm(float3 x) {
    float s = 0.0, a = 0.5;
    for (int k = 0; k < 4; k++) { s += a * vnoise(x); x *= 2.03; a *= 0.5; }
    return s;
}

// Higher-octave fbm — crisper planet detail than the 4-octave granulation `fbm`.
static inline float fbm6(float3 x) {
    float s = 0.0, a = 0.5;
    for (int k = 0; k < 6; k++) { s += a * vnoise(x); x *= 2.02; a *= 0.5; }
    return s;
}
// Ridged noise — sharp crests for cracks, fractures, dune ridges, crater rims.
static inline float ridge(float3 x) { return 1.0 - fabs(fbm6(x) * 2.0 - 1.0); }

// A stable per-planet pseudo-random in [0,1) from the CPU-supplied appearance seed
// (a hash of the body's name + rotation period) plus an index, so several look
// parameters — band count, swirliness, hue jitter, feature placement — decorrelate
// yet stay identical every time the same planet is viewed.
static inline float pr(float seed, float i) {
    return fract(sin(seed * 127.1 + i * 311.7 + 0.5) * 43758.5453123);
}

// Mirror star_vertex's system-focus recession so overlays anchored to stars track
// them as the field pushes radially away from the focused star during a drill. A
// point at the focused star (which sits exactly at orreryCenter) has zero offset,
// so it stays put — matching the sun's exemption in star_vertex without needing a
// per-vertex index check.
static inline float3 overlayPushed(float3 worldPos, constant Uniforms& u) {
    if (u.orreryReveal <= 0.0) return worldPos;
    float3 toStar = worldPos - u.orreryCenter.xyz;
    return u.orreryCenter.xyz + toStar * (1.0 + u.systemPush * u.orreryReveal);
}
