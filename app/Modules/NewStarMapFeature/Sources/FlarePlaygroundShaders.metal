#include <metal_stdlib>
#include "../CShaderTypes/include/ShaderTypes.h"
using namespace metal;

// ---------------------------------------------------------------------------
// Solar-flare playground — a single centred star (corona + disc + flares) drawn
// as one screen-space quad and tone-mapped inline, driven entirely by FlareParams.
// This mirrors the production star_fragment math (Shaders.metal) but reads every
// constant as a live uniform so the sliders in FlarePlayground.swift can tune it.
// Keep the two in sync: once the look is dialled in, copy the values back into the
// production constants.
// ---------------------------------------------------------------------------

// Cheap 3D value noise (duplicated here, file-local, so the playground shader is
// self-contained — the production copies are `static` and not cross-file visible).
static float pgHash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 31.32);
    return fract((p.x + p.y) * p.z);
}
static float pgVnoise(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float c000 = pgHash13(i + float3(0,0,0)), c100 = pgHash13(i + float3(1,0,0));
    float c010 = pgHash13(i + float3(0,1,0)), c110 = pgHash13(i + float3(1,1,0));
    float c001 = pgHash13(i + float3(0,0,1)), c101 = pgHash13(i + float3(1,0,1));
    float c011 = pgHash13(i + float3(0,1,1)), c111 = pgHash13(i + float3(1,1,1));
    float y0 = mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y);
    float y1 = mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y);
    return mix(y0, y1, f.z);
}
static float pgFbm(float3 x) {
    float s = 0.0, a = 0.5;
    for (int k = 0; k < 4; k++) { s += a * pgVnoise(x); x *= 2.03; a *= 0.5; }
    return s;
}

constant float2 kFPCorners[6] = {
    float2(-1, -1), float2( 1, -1), float2(-1,  1),
    float2(-1,  1), float2( 1, -1), float2( 1,  1)
};

struct FPVaryings {
    float4 position [[position]];
    float2 uv;          // [-1,1] across the sprite
};

vertex FPVaryings fp_vertex(uint vid [[vertex_id]], constant FlareParams& P [[buffer(0)]])
{
    float2 c = kFPCorners[vid];
    float2 pos = c * 0.85;                    // fill most of the view
    if (P.aspect >= 1.0) pos.x /= P.aspect;   // keep the star circular
    else                 pos.y *= P.aspect;
    FPVaryings out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = c;
    return out;
}

fragment float4 fp_fragment(FPVaryings in [[stage_in]],
                            constant FlareParams& P    [[buffer(0)]],
                            constant float4x4&   view  [[buffer(1)]])
{
    float2 uv = in.uv;
    float d = length(uv);
    float3 col = P.starColor.rgb;

    // The surface frame: inverse view rotation, then the slow spin about world-up —
    // the SAME transform the disc granulation and the flares share, so they turn
    // together as the camera orbits and the star spins.
    float3x3 viewRot = float3x3(view[0].xyz, view[1].xyz, view[2].xyz);
    float spin = P.time * P.spinRate;
    float cs = cos(spin), sn = sin(spin);

    float3 hdr = float3(0.0);

    // Corona glow — context; fades OUT as the disc resolves (inverse of the flares).
    float glow = pow(saturate(1.0 - d), 2.0);
    float core = pow(saturate(1.0 - d), 8.0);
    float glowFade = 1.0 - smoothstep(0.2, 0.7, P.lod);
    hdr += col * (glow + core * 1.5) * glowFade;

    // Disc — limb-darkened, granulated, anchored to the spinning surface.
    if (d < P.discEdge) {
        float fade = smoothstep(0.2, 0.7, P.lod);
        float mu = sqrt(saturate(1.0 - (d * d) / (P.discEdge * P.discEdge)));
        float shade = 0.6 + 0.4 * pow(mu, 0.5);
        float3 hemi = float3(uv / P.discEdge, mu);
        float3 wd = transpose(viewRot) * hemi;
        wd = float3(wd.x * cs - wd.z * sn, wd.y, wd.x * sn + wd.z * cs);
        // Drift the noise field over time so the granulation cells boil/evolve
        // rather than only rigidly rotating with the spinning surface.
        float gran = pgFbm(wd * 9.0 + float3(0.0, 0.0, P.time * P.granTimeScale));
        float coolness = saturate(col.r - col.b + 0.15);
        float mott = 1.0 + (gran - 0.5) * (0.7 + 0.6 * coolness);
        hdr += col * (P.discBrightness * shade * mott) * fade;
    }

    // Flares — plasma tongues in the annulus, sampled in the star's rotating frame.
    float flareLOD = smoothstep(0.55, 0.92, P.lod);
    if (flareLOD > 0.001 && d > P.discEdge - 0.05) {
        float3 surfDir = transpose(viewRot) * normalize(float3(uv, 0.0));
        surfDir = float3(surfDir.x * cs - surfDir.z * sn, surfDir.y, surfDir.x * sn + surfDir.z * cs);
        float beyond = saturate((d - P.discEdge) / (1.0 - P.discEdge));
        float base  = pgFbm(surfDir * P.baseFreq  + float3(0.0, 0.0, P.time * P.baseTimeScale));
        float flick = pgFbm(surfDir * P.flickFreq + float3(0.0, 0.0, P.time * P.flickTimeScale) + 17.0);
        float height = saturate(base * P.baseWeight + flick * P.flickWeight);
        height = pow(height, P.heightPower);
        float tongue = smoothstep(height, height - P.tongueBand, beyond);
        float radial = 1.0 - beyond * P.radialFalloff;
        float edgeFade = 1.0 - smoothstep(P.edgeFadeStart, 1.0, d);
        float flare = tongue * radial * edgeFade * flareLOD;

        float3 hot  = mix(col, P.hotColor.rgb, P.hotMix);
        float3 cool = mix(col, P.coolColor.rgb, P.coolMix);
        float3 flareColor = mix(hot, cool, beyond);
        hdr += flareColor * (flare * P.intensity);
    }

    // Inline tone-map — one star over black, so no HDR accumulation pass is needed.
    float3 c = hdr * P.exposure;
    c = c / (c + 1.0);
    c = pow(c, float3(1.0 / 2.2));
    return float4(c, 1.0);
}
