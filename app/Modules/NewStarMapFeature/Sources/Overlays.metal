#include "ShaderCommon.h"

// ---------------------------------------------------------------------------
// Mesh overlay — the FTL comms network, drawn additively into the same HDR target
// after the stars. Stateless and symmetric: the opposite visual language to a
// ship's bright directed comet. Two parts:
//   • links  — proximity edges expanded to screen-space quad ribbons
//   • relays — a ring at every relay system, so even an orphan (no links) reads
//
// Links are quads (not 1px line primitives) so thickness, dashes, gradients and
// flow are all shader-only changes later. `along`/`side` carry what those need.
// System-focus recession is mirrored via `overlayPushed` (ShaderCommon.h) so mesh
// anchored to stars tracks them as the field pushes away during a drill.
// ---------------------------------------------------------------------------

struct MeshVaryings {
    float4 position [[position]];
    float  along;
    float  side;
    float  fade;
};

vertex MeshVaryings mesh_vertex(uint vid                          [[vertex_id]],
                                const device MeshLineVertex* verts [[buffer(0)]],
                                constant Uniforms&   u             [[buffer(1)]],
                                constant MeshParams& p             [[buffer(2)]])
{
    MeshLineVertex v = verts[vid];
    float4x4 vp = u.projection * u.view;
    float4 ca = vp * float4(overlayPushed(v.a, u), 1.0);
    float4 cb = vp * float4(overlayPushed(v.b, u), 1.0);

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
    out.fade = u.overlayDim;
    return out;
}

fragment float4 mesh_fragment(MeshVaryings in [[stage_in]])
{
    // Feather the ribbon edges for a smooth line. `along` is available here for
    // dashes/gradients later without touching geometry.
    float aa = 1.0 - smoothstep(0.5, 1.0, abs(in.side));
    return float4(float3(0.16, 0.40, 0.62) * (aa * in.fade), 1.0);
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
    float fade;
    // Screen-space arc-length from endpoint B (the destination), in pixels.
    // Interpolated WITHOUT perspective correction (screen-linear) so a fragment's
    // value is its true pixel distance along the ribbon — that's what makes dashes
    // uniform in screen space even when the trajectory is foreshortened toward/away
    // from the camera. Anchored at B, not A, so the dash cadence stays PINNED to the
    // destination: when the camera auto-orbits the destination star and the line's
    // screen length changes, the fractional slack accumulates at the far (origin)
    // end instead of sliding/rescaling the dashes near the pivot.
    float screenDist [[center_no_perspective]];
};

vertex ShipLineVaryings ship_line_vertex(uint vid                          [[vertex_id]],
                                         const device MeshLineVertex* verts [[buffer(0)]],
                                         constant Uniforms&   u             [[buffer(1)]],
                                         constant MeshParams& p             [[buffer(2)]],
                                         constant ShipParams& s             [[buffer(3)]])
{
    MeshLineVertex v = verts[vid];
    float4x4 vp = u.projection * u.view;
    float4 ca = vp * float4(overlayPushed(v.a, u), 1.0);
    float4 cb = vp * float4(overlayPushed(v.b, u), 1.0);
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
    out.fade = u.overlayDim;
    // 0 at B (destination), full screen length at A; screen-linear interpolation
    // (see the varying) turns this into the fragment's true pixel distance measured
    // BACK from the destination, so the dash pattern is pinned there.
    out.screenDist = (1.0 - v.along) * length(delta);
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
        // Ahead: faint dashed line to the destination. Phase is measured in SCREEN
        // pixels (in.screenDist), so dashes are uniform in screen space along the
        // whole trajectory regardless of perspective foreshortening; the CPU sizes
        // one dash+gap cycle (dashCyclePixels) to the clamped world-target band.
        b = step(0.5, fract(in.screenDist / max(s.dashCyclePixels, 1e-4))) * 0.22;
    }
    return float4(s.color * (b * aa * in.fade), 1.0);
}

// Player / ship-head markers: billboarded at a constant pixel radius, additive.
struct StateMarkerVaryings {
    float4 position [[position]];
    float2 uv;
    float3 color;
    float  style;
    float  radiusPixels;   // marker radius in pixels, for crisp screen-space edges
    float  fade;           // galaxy-overlay fade on drill-in (1 = full, 0 = hidden)
};

vertex StateMarkerVaryings state_marker_vertex(uint vid                        [[vertex_id]],
                                               uint iid                        [[instance_id]],
                                               const device StateMarker* markers [[buffer(0)]],
                                               constant Uniforms&   u          [[buffer(1)]],
                                               constant MeshParams& p          [[buffer(2)]])
{
    StateMarker m = markers[iid];
    float2 corner = kCorners[vid];

    float4 viewPos = u.view * float4(overlayPushed(m.position, u), 1.0);
    float dist = length(viewPos.xyz);
    float w = max(-viewPos.z, 1e-4);

    // For a marker sitting on a star, match the star's on-screen size (same
    // size-encodes-depth band as star_vertex) so the ring encircles the star at
    // any zoom — and never shrink below the pixel floor. worldRadius == 0 means a
    // free marker (ship head), which stays a constant pixel size.
    float radiusPixels = m.radiusPixels;
    if (m.worldRadius > 0.0) {
        float rv = clamp(m.worldRadius, dist * u.minAngularSize, dist * u.maxAngularSize);
        rv *= mix(1.0, u.fieldShrink, u.orreryReveal);    // collapse with the receding field star
        float ys = u.projection[1][1];                    // = 1/tan(fovy/2)
        float starPixels = ys * rv / w * (p.viewportPixels.y * 0.5);
        // Ring clearance past the star disc. The player reticle (style 2) rides a
        // wider multiple so it forms a bold ring OUTSIDE a relay ring on the same
        // star (additive can't occlude); the relay/standard ring hugs the disc.
        float clearance = (m.style > 1.5) ? 1.85 : 1.3;
        radiusPixels = max(radiusPixels, starPixels * clearance);
    }

    float4 clip = u.projection * viewPos;
    clip.xy += corner * (radiusPixels * 2.0 / p.viewportPixels) * clip.w;

    StateMarkerVaryings out;
    out.position = clip;
    out.uv = corner;
    out.color = m.color;
    out.style = m.style;
    out.radiusPixels = radiusPixels;
    out.fade = u.overlayDim;
    return out;
}

fragment float4 state_marker_fragment(StateMarkerVaryings in [[stage_in]])
{
    if (in.style > 0.5 && in.style < 1.5) {
        // Ship comet head: hot core with a soft halo (soft by design).
        float d = length(in.uv);
        float glow = pow(saturate(1.0 - d), 2.0);
        float core = pow(saturate(1.0 - d), 8.0);
        return float4(in.color * ((glow + core * 2.0) * in.fade), 1.0);
    }
    // Crisp reticle ring: a constant PIXEL-thickness annulus whose edges are
    // anti-aliased to ~1px via fwidth — so it stays sharp at any marker size (a
    // fixed UV feather would blur as the marker grows on screen). Style 0 is the
    // relay ring; style 2 is the player's current-location reticle, drawn thicker
    // (and, via the vertex clearance, larger) so it stays unmistakable even when it
    // rides over a relay ring on the same star — additive blending can't occlude,
    // so it has to read by weight and radius.
    float pd = length(in.uv) * in.radiusPixels;   // distance from centre, in pixels
    float outer = in.radiusPixels;                 // outer edge at the quad edge
    float thickness = (in.style > 1.5) ? 9.0 : 6.0;   // player reticle rides heavier
    // Keep a visible hole even at the minimum marker size: never let the ring
    // eat past 60% of the radius, so it always reads as a ring, not a disc.
    float inner = max(outer - thickness, outer * 0.8);
    float aa = max(fwidth(pd), 1e-4);
    float ring = smoothstep(inner - aa, inner + aa, pd)
               - smoothstep(outer - aa, outer + aa, pd);
    return float4(in.color * (saturate(ring) * in.fade), 1.0);
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
