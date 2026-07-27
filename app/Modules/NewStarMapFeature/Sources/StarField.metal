#include "ShaderCommon.h"

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
    float  fieldDim;           // galaxy-fade for system focus (1 = full, 0 = hidden)
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

    bool isFocused = (int(iid) == u.focusedStar);

    // System-focus recession: as the camera drills into a system push the
    // background field radially away from the focused star. Combined with the
    // camera diving inward, the amplified parallax sells "flying in" rather than
    // the field simply fading out. The focused star (the orrery sun) stays put.
    // Pivots on `fieldCenter` (the focused star), NOT `orreryCenter`: at body level
    // the orrery centre tracks the drilled planet around its star, and pivoting the
    // field on a moving point would slide the whole background sky with it.
    if (!isFocused && u.orreryReveal > 0.0) {
        float3 toStar = worldPos - u.fieldCenter.xyz;
        worldPos = u.fieldCenter.xyz + toStar * (1.0 + u.systemPush * u.orreryReveal);
    }

    // Billboard in view space so the quad always faces the camera.
    float4 viewPos = u.view * float4(worldPos, 1.0);
    float dist = length(viewPos.xyz);

    // Size-encodes-depth *within a working band*. Real perspective shrinks the
    // far field for free; we only clamp the extremes: a floor so overview stars
    // don't drop sub-pixel, a ceiling so a near star can't fill the view. The
    // drilled-in star (the orrery sun) lifts the ceiling so it keeps growing —
    // until the camera drills PAST it into a planet (`bodyReveal` 0→1), when the
    // ceiling drops back so the sun recedes from a filled disc to a distant point.
    float ceiling = isFocused ? mix(1e9, u.maxAngularSize, u.bodyReveal) : u.maxAngularSize;
    float radius = clamp(worldRadius, dist * u.minAngularSize, dist * ceiling);

    // Collapse the receding field toward pinpricks as focus deepens (the sun is
    // exempt at system level, but shrinks with `bodyReveal` on the drill INTO a
    // planet so it, too, recedes to a point in space).
    if (!isFocused) radius *= mix(1.0, u.fieldShrink, u.orreryReveal);
    else            radius *= mix(1.0, u.fieldShrink, u.bodyReveal);

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
    // The sun never fades with the galaxy field — but it DOES fade out as the camera
    // drills past it into a planet (`bodyReveal` 0→1), leaving the planet on empty space.
    out.fieldDim = isFocused ? (1.0 - u.bodyReveal) : u.fieldDim;

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
    out.color = m.color;   // ambient stays — it's the medium surrounding the orrery too
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

// ---------------------------------------------------------------------------
// Nebulae — the reworked interstellar clouds (NebulaField.swift). Unlike the
// ambient point sprites above (fixed pixel size → reads as dots), each puff is a
// WORLD-SPACE billboard: its radius is in light-years, so it projects with depth
// and parallaxes as a real volume, and hundreds overlapping read as diffuse gas.
// Additive into the same HDR target, behind everything (no depth). It recedes +
// fades with a system drill-in from the shared `Uniforms`, exactly like the field.
// ---------------------------------------------------------------------------

struct NebulaVaryings {
    float4 position [[position]];
    float2 uv;                           // [-1,1] across the sprite, for the falloff
    float4 color;                        // rgb = tint, a = opacity (already field-faded)
};

vertex NebulaVaryings nebula_vertex(uint vid                       [[vertex_id]],
                                    uint iid                       [[instance_id]],
                                    const device NebulaPuff*       puffs [[buffer(0)]],
                                    constant Uniforms&             u     [[buffer(1)]],
                                    constant NebulaRenderParams&   np    [[buffer(2)]])
{
    NebulaPuff m = puffs[iid];

    // The nebulae are a fixed distant backdrop: unlike the star field they do NOT
    // recede/shrink on a system drill-in (they're the far sky, not local geometry).
    // They only fade with the galaxy via `fieldDim`.
    float4 viewPos = u.view * float4(m.positionSize.xyz, 1.0);
    float2 c = kCorners[vid];
    float r = m.positionSize.w * np.sizeScale;
    viewPos.xy += c * r;

    NebulaVaryings out;
    out.position = u.projection * viewPos;
    out.uv = c;
    out.color = float4(m.color.rgb, m.color.a * u.fieldDim);   // fade with the galaxy
    return out;
}

fragment float4 nebula_fragment(NebulaVaryings in            [[stage_in]],
                                constant NebulaRenderParams& np [[buffer(0)]])
{
    float d = length(in.uv);
    float soft = max(np.softness, 0.1);
    float body = pow(saturate(1.0 - d), soft);
    float core = pow(saturate(1.0 - d), soft * 4.0) * np.coreBoost;
    float alpha = in.color.a * np.brightness * (body + core);

    float3 rgb = in.color.rgb;
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, np.saturation);

    return float4(rgb * alpha, 1.0);   // premultiplied for pure-additive blend
}

// Sphere radius within the sprite quad — the disc fills this, the flares live in
// the annulus beyond it. Shared by the glow, flare, and body passes so they agree.
constant float kDiscEdge = 0.798;

// Solar flares — animated plasma tongues licking off the limb. They exist only at
// the highest LOD (the inverse of the corona glow, which fades OUT as the disc
// resolves), living in the annulus between the disc edge and the sprite edge.
//
// `surfDir` is the limb direction rotated into the star's OWN spinning frame (the
// same world-space rotation the granulation uses), so tongues erupt from fixed
// longitudes and rotate into/out of view with the surface rather than sliding
// across the screen. Two evolving fbm layers make them rise, flicker, and fall
// back; a tongue fills from the limb out to its (noise-driven) height. Returns an
// additive intensity in 0…~1.
static float starFlare(float3 surfDir, float d, float lod, float time) {
    float flareLOD = smoothstep(0.55, 0.92, lod);              // only near/resolved stars
    if (flareLOD < 0.001 || d < kDiscEdge - 0.05) return 0.0;   // skip the disc interior
    float beyond = saturate((d - kDiscEdge) / (1.0 - kDiscEdge));   // 0 at limb → 1 at edge
    // Slow base swell + a faster flicker, sampled in the star's rotating frame with
    // a temporal drift so the tongues live and breathe.
    float base  = fbm(surfDir * 3.0    + float3(0.0, 0.0, time * 0.30));
    float flick = fbm(surfDir * 10.548 + float3(0.0, 0.0, time * 0.55) + 17.0);
    float height = saturate(base * 0.528 + flick * 0.536);     // this tongue's reach
    height = pow(height, 1.953);                               // sharpen → spiky, not blobby
    float tongue = smoothstep(height, height - 0.457, beyond); // filled up to `height`
    float radial = 1.0 - beyond * 0.455;                       // brighter at the base
    float edgeFade = 1.0 - smoothstep(0.749, 1.0, d);          // soften the sprite edge
    return tongue * radial * edgeFade * flareLOD;
}

// Glow pass — the additive far-field look: a soft radial glow with a hotter core,
// a point of light. The dense pass; no depth (Invariant 8). For a resolved star the
// opaque body (below) over-blends on top, so this becomes its surrounding corona —
// and its animated solar flares, which lick off the limb at the highest LOD.
fragment float4 star_fragment(StarVaryings in [[stage_in]],
                              constant Uniforms& u [[buffer(2)]])
{
    float d = length(in.uv);
    float glow = pow(saturate(1.0 - d), 2.0);
    float core = pow(saturate(1.0 - d), 8.0);
    // Cross-fade with the disc: the glow fades OUT as the disc fades IN (same lod
    // ramp as star_body_fragment's `fade`), so a resolved star reads as its disc,
    // not a disc with the glow bleeding through when it's transparent.
    float glowFade = 1.0 - smoothstep(0.2, 0.7, in.lod);
    float intensity = (glow + core * 1.5) * in.brightness * glowFade * in.fieldDim;

    // Flares ramp IN as the glow fades out, so a resolved star reads as a clean disc
    // with plasma tongues against space. Anchor the noise to the star's spinning
    // surface: reconstruct the limb direction in view space, rotate it back to world
    // by the inverse view rotation, then apply the SAME slow spin as the granulation
    // (star_body_fragment), so flares and surface features turn together.
    float3x3 viewRot = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3 surfDir = transpose(viewRot) * normalize(float3(in.uv, 0.0));
    float a = u.time * 0.12, ca = cos(a), sa = sin(a);
    surfDir = float3(surfDir.x * ca - surfDir.z * sa, surfDir.y, surfDir.x * sa + surfDir.z * ca);
    float flare = starFlare(surfDir, d, in.lod, u.time);

    // Their own plasma colour, distinct from the disc: a hot near-white base cooling
    // to a deep ember tip, biased by the star's hue so it still belongs to the star.
    float beyond = saturate((d - kDiscEdge) / (1.0 - kDiscEdge));
    float3 hot  = mix(in.color, float3(1.00, 0.82, 0.50), 0.604);  // near-limb, bright
    float3 cool = mix(in.color, float3(0.95, 0.20, 0.05), 0.896);  // tip, deep ember
    float3 flareColor = mix(hot, cool, beyond);
    float flareI = flare * 0.348 * in.brightness * in.fieldDim;

    return float4(in.color * intensity + flareColor * flareI, 1.0);
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
    const float discEdge = kDiscEdge;               // sphere radius within the quad
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
    float a = u.time * 0.12;                         // slow spin (locked to the flare spin)
    float ca = cos(a), sa = sin(a);
    wd = float3(wd.x * ca - wd.z * sa, wd.y, wd.x * sa + wd.z * ca);
    // Drift the noise field over time so the granulation cells boil/evolve rather
    // than only rigidly rotating with the spinning surface.
    float gran = fbm(wd * 9.0 + float3(0.0, 0.0, u.time * 0.29));
    // Every star gets a visible granulation floor (so a near-white ~#dcdcdc sun
    // isn't a flat disc), with cool stars mottled a touch harder on top of it.
    float coolness = saturate(in.color.r - in.color.b + 0.15);
    float mott = 1.0 + (gran - 0.5) * (0.7 + 0.6 * coolness);

    const float discBrightness = 2.2;
    float3 rgb = in.color * (discBrightness * shade * mott);                 // full look, undimmed
    float coverage = smoothstep(discEdge, discEdge - fwidth(d) - 0.01, d);   // soft AA limb
    float outAlpha = coverage * fade * in.brightness * in.fieldDim;          // opacity ∝ relevance, faded on drill-in
    if (outAlpha < 0.003) discard_fragment();   // fully-faded stars don't write depth (so the orrery shows through)
    return float4(rgb, outAlpha);
}
