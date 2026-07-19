#include <metal_stdlib>
#include "../CShaderTypes/include/ShaderTypes.h"
using namespace metal;

// ---------------------------------------------------------------------------
// Nebula playground shaders — a self-contained two-pass renderer for tuning the
// reworked nebulae (NebulaField.swift / NebulaPlayground.swift):
//
//   Pass 1 (HDR accumulation, additive, rgba16Float):
//     • neb_star_vertex/fragment   — the representative surveyed-star scatter as
//       soft point sprites, so the star-diffusion of the clouds is visible.
//     • neb_nebula_vertex/fragment — the dust clouds as soft WORLD-SPACE billboard
//       puffs (radius in ly → real depth + parallax), many overlapping = diffuse gas.
//
//   Pass 2 (tone-map to the drawable):
//     • neb_fullscreen_vertex + neb_tonemap_fragment — Reinhard + gamma, so the
//       additive clouds don't clip to white where hundreds of puffs pile up.
//
// Kept file-local (its own corners; no ShaderCommon dependency) like the flare
// playground, so it can't collide with the production passes.
// ---------------------------------------------------------------------------

constant float2 kNebCorners[6] = {
    float2(-1, -1), float2( 1, -1), float2(-1,  1),
    float2(-1,  1), float2( 1, -1), float2( 1,  1)
};

// MARK: - Nebula puffs (world-space billboards)

struct NebVaryings {
    float4 position [[position]];
    float2 uv;          // [-1,1] across the sprite, for the radial falloff
    float4 color;       // rgb = tint, a = per-puff opacity
};

vertex NebVaryings neb_nebula_vertex(uint vid                    [[vertex_id]],
                                     uint iid                    [[instance_id]],
                                     const device NebulaPuff*    puffs [[buffer(0)]],
                                     constant NebulaUniforms&    u     [[buffer(1)]])
{
    NebulaPuff m = puffs[iid];
    float4 viewPos = u.view * float4(m.positionSize.xyz, 1.0);
    float2 c = kNebCorners[vid];
    // Billboard in view space: the quad always faces the camera, sized in WORLD
    // units so it shrinks with distance (real depth cue, unlike a pixel point).
    viewPos.xy += c * (m.positionSize.w * u.sizeScale);

    NebVaryings out;
    out.position = u.projection * viewPos;
    out.uv = c;
    out.color = m.color;
    return out;
}

fragment float4 neb_nebula_fragment(NebVaryings in [[stage_in]],
                                    constant NebulaUniforms& u [[buffer(0)]])
{
    float d = length(in.uv);
    float soft = max(u.softness, 0.1);
    // Soft radial body + a tighter, brighter core — the additive pile-up of many of
    // these reads as glowing gas with denser knots.
    float body = pow(saturate(1.0 - d), soft);
    float core = pow(saturate(1.0 - d), soft * 4.0) * u.coreBoost;
    float alpha = in.color.a * u.brightness * (body + core);

    // Saturation control around luma.
    float3 rgb = in.color.rgb;
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, u.saturation);

    // Premultiplied for pure-additive blend (src.one, dst.one); alpha channel unused.
    return float4(rgb * alpha, 1.0);
}

// MARK: - Stars (point sprites)

struct NebStarVaryings {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float3 color;
};

vertex NebStarVaryings neb_star_vertex(uint vid                   [[vertex_id]],
                                       const device StarInstance* stars [[buffer(0)]],
                                       constant NebulaUniforms&   u     [[buffer(1)]])
{
    StarInstance s = stars[vid];
    float4 viewPos = u.view * float4(s.positionRadius.xyz, 1.0);
    float dist = max(length(viewPos.xyz), 1.0);

    NebStarVaryings out;
    out.position = u.projection * viewPos;
    out.pointSize = clamp(2200.0 / dist, 1.5, 7.0);   // shrink with depth
    out.color = s.color.rgb;
    return out;
}

fragment float4 neb_star_fragment(NebStarVaryings in [[stage_in]],
                                  float2 pc          [[point_coord]])
{
    float d = length(pc - float2(0.5));
    float a = saturate(1.0 - d * 2.0);
    a *= a;
    float core = pow(a, 4.0);
    return float4(in.color * (a + core * 1.5) * 0.9, 1.0);
}

// MARK: - Tone-map (HDR → drawable)

struct NebFSVaryings { float4 position [[position]]; };

vertex NebFSVaryings neb_fullscreen_vertex(uint vid [[vertex_id]])
{
    NebFSVaryings out;
    out.position = float4(kNebCorners[vid], 0.0, 1.0);   // full-screen quad
    return out;
}

fragment float4 neb_tonemap_fragment(NebFSVaryings in [[stage_in]],
                                     constant NebulaUniforms&           u   [[buffer(0)]],
                                     texture2d<float, access::read>     hdr [[texture(0)]])
{
    // The HDR target matches the drawable size 1:1, so fragment position == texel.
    float3 c = hdr.read(uint2(in.position.xy)).rgb * u.exposure;
    c = c / (c + 1.0);                    // Reinhard
    c = pow(c, float3(1.0 / 2.2));        // gamma
    return float4(c, 1.0);
}
