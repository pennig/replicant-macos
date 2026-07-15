#include <metal_stdlib>
#include "../CShaderTypes/include/ShaderTypes.h"
using namespace metal;

// ---------------------------------------------------------------------------
// Pass 2 — Tone-map the accumulated HDR field as a whole.
//
// This is what stops the dense core from clipping to a white blob: we sum in
// linear HDR, then compress the highlights on the way to the drawable. Without
// this pass the center of the galaxy is a smear; with it, structure resolves.
// ---------------------------------------------------------------------------

struct FullscreenVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVaryings fullscreen_vertex(uint vid [[vertex_id]])
{
    // One oversized triangle covering the screen.
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenVaryings out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 tonemap_fragment(FullscreenVaryings in [[stage_in]],
                                 texture2d<float> hdr [[texture(0)]],
                                 constant Uniforms& u [[buffer(0)]])
{
    constexpr sampler s(filter::nearest);
    float3 c = hdr.sample(s, in.uv).rgb;

    // Exposure + a simple filmic-ish compression. Reinhard would also do; this
    // holds a little more contrast in the mid-tones of the arms.
    c *= u.exposure;
    c = c / (c + 1.0);                 // highlight compression
    c = pow(c, float3(1.0 / 2.2));     // to gamma space for the bgra8 drawable
    return float4(c, 1.0);
}
