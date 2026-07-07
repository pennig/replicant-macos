#include <metal_stdlib>
#include "../CShaderTypes/include/ShaderTypes.h"
using namespace metal;

// ---------------------------------------------------------------------------
// Pass 1 — Terrain: 10k instanced billboards, additive, into an HDR target.
//
// No vertex buffer: the quad corners come from vertex_id (0..5) and the star
// comes from instance_id. Additive blending is order-independent, so this pass
// needs no depth buffer and no sorting — the one gift the dense field hands us.
// ---------------------------------------------------------------------------

struct StarVaryings {
    float4 position [[position]];
    float2 uv;                 // [-1,1] across the sprite; for the radial glow
    float3 color;
    float  brightness;         // atmospheric depth * semantic relevance
    float  lod;                // 0 = far/glow sprite, 1 = near/luminous disc
};

// Two triangles → a quad, expressed as corner offsets.
constant float2 kCorners[6] = {
    float2(-1, -1), float2( 1, -1), float2(-1,  1),
    float2(-1,  1), float2( 1, -1), float2( 1,  1)
};

vertex StarVaryings star_vertex(uint vid                    [[vertex_id]],
                                uint iid                    [[instance_id]],
                                const device StarInstance*  stars     [[buffer(0)]],
                                const device float*         relevance [[buffer(1)]],
                                constant Uniforms&          u         [[buffer(2)]])
{
    StarVaryings out;

    StarInstance s = stars[iid];
    float3 worldPos = s.positionRadius.xyz;
    float  worldRadius = s.positionRadius.w;

    // Billboard in view space so the quad always faces the camera.
    float4 viewPos = u.view * float4(worldPos, 1.0);
    float dist = length(viewPos.xyz);

    // Size-encodes-depth *within a working band*. Real perspective shrinks the
    // far field for free; we only clamp the extremes: a floor so overview stars
    // don't drop sub-pixel, a ceiling so a near star can't fill the view.
    float radius = clamp(worldRadius, dist * u.minAngularSize, dist * u.maxAngularSize);

    float2 corner = kCorners[vid];
    viewPos.xy += corner * radius;

    out.position = u.projection * viewPos;
    out.uv = corner;
    out.color = s.color.rgb;

    // LOD from on-screen angular size: the same distance-driven state as the size
    // band, so a star resolves from glow → disc as it grows on screen (no pop).
    out.lod = smoothstep(u.lodStart, u.lodFull, radius / max(dist, 1e-4));

    // Two cues, relayed:
    //  - atmospheric depth attenuation, computed live from view distance
    //  - semantic relevance, read from the buffer overlays write (1.0 = terrain)
    float t = saturate((dist - u.atmoNear) / max(u.atmoFar - u.atmoNear, 1e-4));
    float atmo = mix(1.0, u.atmoFloor, t);
    out.brightness = atmo * relevance[iid];

    return out;
}

// ---------------------------------------------------------------------------
// Ambient field — the interstellar medium between the charted systems: a faint
// dust haze, soft nebula clouds, hot proto-star glints, and a distant star shell.
// One additive point-sprite draw behind everything (no depth). The soft round
// falloff reads as fuzzy gas rather than hard dots; the tone-map keeps the dense
// clouds from blowing out (the additive analogue of SceneKit's screen blend).
// ---------------------------------------------------------------------------

struct AmbientVaryings {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;                        // rgb = tint, a = brightness
};

vertex AmbientVaryings ambient_vertex(uint vid                     [[vertex_id]],
                                      const device AmbientVertex*   motes [[buffer(0)]],
                                      constant Uniforms&            u     [[buffer(1)]])
{
    AmbientVaryings out;
    AmbientVertex m = motes[vid];
    out.position = u.projection * (u.view * float4(m.positionSize.xyz, 1.0));
    out.pointSize = clamp(m.positionSize.w, 1.0, 6.0);
    out.color = m.color;
    return out;
}

fragment float4 ambient_fragment(AmbientVaryings in [[stage_in]],
                                 float2 pc          [[point_coord]])
{
    // Soft round falloff (point_coord is [0,1] across the sprite).
    float d = length(pc - float2(0.5));
    float a = saturate(1.0 - d * 2.0);
    a *= a;
    return float4(in.color.rgb * (in.color.a * a), 1.0);
}

// Cheap 3D value noise for stellar granulation.
static float hash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 31.32);
    return fract((p.x + p.y) * p.z);
}
static float vnoise(float3 x) {
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
static float fbm(float3 x) {
    float s = 0.0, a = 0.5;
    for (int k = 0; k < 3; k++) { s += a * vnoise(x); x *= 2.03; a *= 0.5; }
    return s;
}

// Glow pass — the additive far-field look: a soft radial glow with a hotter core,
// a point of light. The dense pass; no depth (Invariant 8). For a resolved star the
// opaque body (below) over-blends on top, so this becomes its surrounding corona.
fragment float4 star_fragment(StarVaryings in [[stage_in]])
{
    float d = length(in.uv);
    float glow = pow(saturate(1.0 - d), 2.0);
    float core = pow(saturate(1.0 - d), 8.0);
    // Cross-fade with the disc: the glow fades OUT as the disc fades IN (same lod
    // ramp as star_body_fragment's `fade`), so a resolved star reads as its disc,
    // not a disc with the glow bleeding through when it's transparent.
    float glowFade = 1.0 - smoothstep(0.2, 0.7, in.lod);
    float intensity = (glow + core * 1.5) * in.brightness * glowFade;
    return float4(in.color * intensity, 1.0);
}

// Body pass — the near look: a luminous primary rendered OPAQUE (over-blend +
// depth) so it covers the field behind it and occludes/other bodies. Only
// resolved (`lod`), relevant (`brightness`) stars get a solid body; the rest stay
// glows. Fades in with lod so the glow→disc transition doesn't pop.
fragment float4 star_body_fragment(StarVaryings in [[stage_in]],
                                   constant Uniforms& u        [[buffer(2)]],
                                   constant float2&   relRange [[buffer(3)]])
{
    float d = length(in.uv);
    const float discEdge = 0.72;                    // sphere radius within the quad
    float fade = smoothstep(0.2, 0.7, in.lod);      // LOD ramps in with lod — CAMERA-tied only

    // Two draws split the relevance range: the opaque slice (≥ threshold) writes
    // depth and occludes; the dim slice is drawn transparent afterwards, depth-
    // tested but NOT writing. Dimming is PURE OPACITY (alpha ∝ relevance) and
    // separate from LOD — a dimmed star looks identical, just more see-through.
    if (d > discEdge || fade < 0.02 ||
        in.brightness < relRange.x || in.brightness >= relRange.y) discard_fragment();

    float mu = sqrt(saturate(1.0 - (d * d) / (discEdge * discEdge)));   // 1 centre → 0 limb
    float shade = 0.6 + 0.4 * pow(mu, 0.5);                             // limb darkening

    // Granulation sampled in the star's WORLD space (not the billboard), so
    // orbiting reveals different surface — real sphere parallax — and it spins
    // slowly over time. Transform the view-space hemisphere point back to world by
    // the inverse (transpose) of the view rotation, then rotate about world-up.
    float3 hemi = float3(in.uv / discEdge, mu);
    float3x3 viewRot = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3 wd = transpose(viewRot) * hemi;
    float a = u.time * 0.15;                         // slow spin
    float ca = cos(a), sa = sin(a);
    wd = float3(wd.x * ca - wd.z * sa, wd.y, wd.x * sa + wd.z * ca);
    float gran = fbm(wd * 7.0);
    float coolness = saturate(in.color.r - in.color.b + 0.15);
    float mott = 1.0 + (gran - 0.5) * 0.7 * coolness;

    const float discBrightness = 2.2;
    float3 rgb = in.color * (discBrightness * shade * mott);                 // full look, undimmed
    float coverage = smoothstep(discEdge, discEdge - fwidth(d) - 0.01, d);   // soft AA limb
    return float4(rgb, coverage * fade * in.brightness);                     // opacity ∝ relevance
}

// ---------------------------------------------------------------------------
// Mesh overlay — the FTL comms network, drawn additively into the same HDR target
// after the stars. Stateless and symmetric: the opposite visual language to a
// ship's bright directed comet. Two parts:
//   • links  — proximity edges expanded to screen-space quad ribbons
//   • relays — a ring at every relay system, so even an orphan (no links) reads
//
// Links are quads (not 1px line primitives) so thickness, dashes, gradients and
// flow are all shader-only changes later. `along`/`side` carry what those need.
// ---------------------------------------------------------------------------

struct MeshVaryings {
    float4 position [[position]];
    float  along;
    float  side;
};

vertex MeshVaryings mesh_vertex(uint vid                          [[vertex_id]],
                                const device MeshLineVertex* verts [[buffer(0)]],
                                constant Uniforms&   u             [[buffer(1)]],
                                constant MeshParams& p             [[buffer(2)]])
{
    MeshLineVertex v = verts[vid];
    float4x4 vp = u.projection * u.view;
    float4 ca = vp * float4(v.a, 1.0);
    float4 cb = vp * float4(v.b, 1.0);

    // Screen-space perpendicular, so thickness is constant in pixels regardless
    // of depth or zoom. (Endpoints behind the camera aren't near-plane clipped
    // yet — fine for a mesh sitting inside the field.)
    float2 screenA = (ca.xy / ca.w) * 0.5 * p.viewportPixels;
    float2 screenB = (cb.xy / cb.w) * 0.5 * p.viewportPixels;
    float2 delta = screenB - screenA;
    float2 dir = delta / max(length(delta), 1e-4);
    float2 normal = float2(-dir.y, dir.x);

    float4 clip = mix(ca, cb, v.along);
    float2 offsetPx = normal * v.side * p.halfWidthPixels;
    clip.xy += (offsetPx * 2.0 / p.viewportPixels) * clip.w;   // survive the perspective divide

    MeshVaryings out;
    out.position = clip;
    out.along = v.along;
    out.side = v.side;
    return out;
}

fragment float4 mesh_fragment(MeshVaryings in [[stage_in]])
{
    // Feather the ribbon edges for a smooth line. `along` is available here for
    // dashes/gradients later without touching geometry.
    float aa = 1.0 - smoothstep(0.5, 1.0, abs(in.side));
    return float4(float3(0.16, 0.40, 0.62) * aa, 1.0);
}

// ---------------------------------------------------------------------------
// State overlay — the player and their ships (HANDOFF §2 tier 3): tiny, always
// visible, top of the hierarchy, NEVER dimmed (drawn additively without reading
// the relevance buffer). A ship reads as motion with a heading — a bright comet
// head, a fading tail, and a dashed remainder to the destination — the opposite
// of the faint static mesh. Trajectories are direct point-to-point (HANDOFF §1).
// ---------------------------------------------------------------------------

// Ship trajectory ribbon. Same screen-space quad expansion as the mesh links, but
// its own fragment language: tail behind the head, dashes ahead.
struct ShipLineVaryings {
    float4 position [[position]];
    float along;
    float side;
};

vertex ShipLineVaryings ship_line_vertex(uint vid                          [[vertex_id]],
                                         const device MeshLineVertex* verts [[buffer(0)]],
                                         constant Uniforms&   u             [[buffer(1)]],
                                         constant MeshParams& p             [[buffer(2)]],
                                         constant ShipParams& s             [[buffer(3)]])
{
    MeshLineVertex v = verts[vid];
    float4x4 vp = u.projection * u.view;
    float4 ca = vp * float4(v.a, 1.0);
    float4 cb = vp * float4(v.b, 1.0);
    float2 screenA = (ca.xy / ca.w) * 0.5 * p.viewportPixels;
    float2 screenB = (cb.xy / cb.w) * 0.5 * p.viewportPixels;
    float2 delta = screenB - screenA;
    float2 dir = delta / max(length(delta), 1e-4);
    float2 normal = float2(-dir.y, dir.x);
    float4 clip = mix(ca, cb, v.along);
    clip.xy += (normal * v.side * s.halfWidthPixels * 2.0 / p.viewportPixels) * clip.w;
    ShipLineVaryings out;
    out.position = clip;
    out.along = v.along;
    out.side = v.side;
    return out;
}

fragment float4 ship_line_fragment(ShipLineVaryings in [[stage_in]],
                                   constant ShipParams& s [[buffer(0)]])
{
    float aa = 1.0 - smoothstep(0.5, 1.0, abs(in.side));   // ribbon edge feather
    float b;
    if (in.along <= s.progress) {
        // Travelled: a tail that's brightest at the head and fades back.
        float back = s.progress - in.along;
        float f = saturate(1.0 - back / max(s.tailLength, 1e-4));
        b = f * f;
    } else {
        // Ahead: faint dashed line to the destination.
        b = step(0.5, fract(in.along * s.dashPeriod)) * 0.22;
    }
    return float4(s.color * (b * aa), 1.0);
}

// Player / ship-head markers: billboarded at a constant pixel radius, additive.
struct StateMarkerVaryings {
    float4 position [[position]];
    float2 uv;
    float3 color;
    float  style;
    float  radiusPixels;   // marker radius in pixels, for crisp screen-space edges
};

vertex StateMarkerVaryings state_marker_vertex(uint vid                        [[vertex_id]],
                                               uint iid                        [[instance_id]],
                                               const device StateMarker* markers [[buffer(0)]],
                                               constant Uniforms&   u          [[buffer(1)]],
                                               constant MeshParams& p          [[buffer(2)]])
{
    StateMarker m = markers[iid];
    float2 corner = kCorners[vid];

    float4 viewPos = u.view * float4(m.position, 1.0);
    float dist = length(viewPos.xyz);
    float w = max(-viewPos.z, 1e-4);

    // For a marker sitting on a star, match the star's on-screen size (same
    // size-encodes-depth band as star_vertex) so the ring encircles the star at
    // any zoom — and never shrink below the pixel floor. worldRadius == 0 means a
    // free marker (ship head), which stays a constant pixel size.
    float radiusPixels = m.radiusPixels;
    if (m.worldRadius > 0.0) {
        float rv = clamp(m.worldRadius, dist * u.minAngularSize, dist * u.maxAngularSize);
        float ys = u.projection[1][1];                    // = 1/tan(fovy/2)
        float starPixels = ys * rv / w * (p.viewportPixels.y * 0.5);
        radiusPixels = max(radiusPixels, starPixels * 1.3);   // 1.3 → ring clears the star disc
    }

    float4 clip = u.projection * viewPos;
    clip.xy += corner * (radiusPixels * 2.0 / p.viewportPixels) * clip.w;

    StateMarkerVaryings out;
    out.position = clip;
    out.uv = corner;
    out.color = m.color;
    out.style = m.style;
    out.radiusPixels = radiusPixels;
    return out;
}

fragment float4 state_marker_fragment(StateMarkerVaryings in [[stage_in]])
{
    if (in.style < 0.5) {
        // Crisp reticle ring: a constant PIXEL-thickness annulus whose edges are
        // anti-aliased to ~1px via fwidth — so it stays sharp at any marker size
        // (a fixed UV feather would blur as the marker grows on screen).
        float pd = length(in.uv) * in.radiusPixels;   // distance from centre, in pixels
        float outer = in.radiusPixels;                 // outer edge at the quad edge
        float thickness = 6.0;                         // ring thickness in pixels
        // Keep a visible hole even at the minimum marker size: never let the ring
        // eat past 60% of the radius, so it always reads as a ring, not a disc.
        float inner = max(outer - thickness, outer * 0.8);
        float aa = max(fwidth(pd), 1e-4);
        float ring = smoothstep(inner - aa, inner + aa, pd)
                   - smoothstep(outer - aa, outer + aa, pd);
        return float4(in.color * saturate(ring), 1.0);
    }
    // Ship comet head: hot core with a soft halo (soft by design).
    float d = length(in.uv);
    float glow = pow(saturate(1.0 - d), 2.0);
    float core = pow(saturate(1.0 - d), 8.0);
    return float4(in.color * (glow + core * 2.0), 1.0);
}

// ---------------------------------------------------------------------------
// Label pass — curated system names as screen-space textured quads, drawn over
// the tone-mapped drawable (so they're never dimmed). One draw per label with its
// own cached glyph texture; positions/collision are resolved on the CPU.
// ---------------------------------------------------------------------------

constant float2 kLabelCorners[6] = {
    float2(0, 0), float2(1, 0), float2(0, 1),
    float2(0, 1), float2(1, 0), float2(1, 1)
};

struct LabelVaryings {
    float4 position [[position]];
    float2 uv;
    float  opacity;
};

vertex LabelVaryings label_vertex(uint vid [[vertex_id]], constant LabelParams& L [[buffer(0)]])
{
    float2 corner = kLabelCorners[vid];
    float2 px = L.originPx + corner * L.sizePx;
    float2 ndc = float2(px.x / L.viewportPx.x * 2.0 - 1.0,
                        1.0 - px.y / L.viewportPx.y * 2.0);   // flip Y to top-left origin
    LabelVaryings out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = corner;
    out.opacity = L.opacity;
    return out;
}

fragment float4 label_fragment(LabelVaryings in [[stage_in]],
                               texture2d<float> glyphs [[texture(0)]])
{
    constexpr sampler s(filter::linear);
    // The CGBitmapContext bytes are already top-down (row 0 = top), matching the
    // texture's v axis, so uv maps directly — no flip. Scaling premultiplied RGBA
    // by opacity keeps it premultiplied, so the fade composites correctly.
    return glyphs.sample(s, in.uv) * in.opacity;
}

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
