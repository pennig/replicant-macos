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
    float  fieldDim;           // galaxy-fade for system focus (1 = full, 0 = hidden)
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

    bool isFocused = (int(iid) == u.focusedStar);

    // System-focus recession: as the camera drills into a system push the
    // background field radially away from the focused star. Combined with the
    // camera diving inward, the amplified parallax sells "flying in" rather than
    // the field simply fading out. The focused star (the orrery sun) stays put.
    if (!isFocused && u.orreryReveal > 0.0) {
        float3 toStar = worldPos - u.orreryCenter.xyz;
        worldPos = u.orreryCenter.xyz + toStar * (1.0 + u.systemPush * u.orreryReveal);
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
    for (int k = 0; k < 4; k++) { s += a * vnoise(x); x *= 2.03; a *= 0.5; }
    return s;
}

// Higher-octave fbm — crisper planet detail than the 4-octave granulation `fbm`.
static float fbm6(float3 x) {
    float s = 0.0, a = 0.5;
    for (int k = 0; k < 6; k++) { s += a * vnoise(x); x *= 2.02; a *= 0.5; }
    return s;
}
// Ridged noise — sharp crests for cracks, fractures, dune ridges, crater rims.
static float ridge(float3 x) { return 1.0 - fabs(fbm6(x) * 2.0 - 1.0); }

// A stable per-planet pseudo-random in [0,1) from the CPU-supplied appearance seed
// (a hash of the body's name + rotation period) plus an index, so several look
// parameters — band count, swirliness, hue jitter, feature placement — decorrelate
// yet stay identical every time the same planet is viewed.
static float pr(float seed, float i) {
    return fract(sin(seed * 127.1 + i * 311.7 + 0.5) * 43758.5453123);
}

// Procedural planet surface for the orrery body impostors. `dir` is the world-space
// sphere normal (already spun about the pole), `style` selects the terrain family
// (matches PlanetSurfaceStyle), `base`/`detail` are the two albedos, `life` (0…1)
// grows a biosphere, `t` is the animation clock. Returns the (unlit) albedo plus a
// self-illuminated `emissive` term (lava cracks, city lights) that survives the
// day/night terminator.
struct OrrerySurface { float3 albedo; float3 emissive; };

// Push a colour away from its own luma (grey), boosting saturation. `factor` > 1
// saturates, 1 leaves it unchanged. Mirrors PlanetMaterial.saturated on the CPU.
static float3 saturateColor(float3 c, float factor) {
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    return saturate(luma + (c - luma) * factor);
}

// Baked terrestrial-atmosphere "feel" constants — surface cloud cover and the halo
// shell. These were dialed in live against a real planet up close (via an on-screen
// slider panel), then frozen here as the production look. Read by orrerySurface /
// orrery_body_fragment (clouds) and orrery_atmosphere_{vertex,fragment} (halo).
constant float kCloudAmount    = 0.824;   // global × on per-body cloud coverage
constant float kCloudScale     = 5.864;   // cloud noise frequency
constant float kCloudSpeed     = 0.165;   // longitudinal drift speed
constant float kCloudSharpness = 0.300;   // coverage smoothstep width (larger = softer)
constant float kCloudOpacity   = 0.850;   // whiteness of full cloud cover
constant float kCloudDrift     = 0.088;   // deck rotation rate ADDED to the surface spin
constant float kCloudHeight    = 0.050;   // parallax elevation of the deck (0 = flush)
constant float kHaloExtent     = 1.001;   // global × on per-body shell extent
constant float kHaloDensity    = 1.309;   // global × on per-body shell density
constant float kHaloFalloff    = 4.044;   // limb→edge decay exponent
constant float kHaloDayWeight  = 0.883;   // sunlit-side bias (0 = uniform … 1 = day-biased)
constant float kHaloIntensity  = 1.609;   // overall halo brightness scale

// `mods` are the tag-driven intensity nudges (PlanetMaterial.SurfaceModifiers):
// x = crater relief ×, y = cloud/atmosphere ×, z = lava emissive ×, w = frost (0…1).
// Neutral (1,1,1,0) reproduces the untagged look for each style. `polarIce` (0…1) is
// the temperature-driven polar ice-cap amount (CPU-gated to cold desert/terran types).
// `sd` is the stable per-planet appearance seed — everything derived from it (band
// count, swirliness, hue jitter, feature placement) is identical every time viewed.
static OrrerySurface orrerySurface(float3 dir, float3 cloudDir, int style, float3 base, float3 detail,
                                   float life, float4 mods, float polarIce, float greenVibrancy, float sd, float t) {
    OrrerySurface s;
    s.emissive = float3(0.0);
    float lat = dir.y;                           // -1 (south) … 1 (north)
    float lon = atan2(dir.z, dir.x);             // -pi … pi

    // Decorrelated per-planet look parameters + a small stable hue jitter so two
    // planets of the same type never look identical.
    float r0 = pr(sd, 1.0), r1 = pr(sd, 2.0), r2 = pr(sd, 3.0), r3 = pr(sd, 4.0);
    float3 hj = (float3(pr(sd, 5.0), pr(sd, 6.0), pr(sd, 7.0)) - 0.5) * 0.14;
    base   = saturate(base + hj);
    detail = saturate(detail + hj);
    s.albedo = base;

    float n   = fbm6(dir * 3.0  + sd * 10.0);
    float nHi = fbm6(dir * 11.0 + sd * 20.0);

    if (style == 1) {                            // GAS GIANT — many bands, seeded variety
        // r0 → band count, r1 → swirliness (0 = straight/diffuse Saturn, 1 = swirly
        // high-contrast Jupiter). Swirl domain-warps the band latitude and sharpens tone.
        float bandCount = mix(7.0, 18.0, r0);
        float swirl     = r1;
        float warp = (fbm6(dir * float3(3.0, 6.0, 3.0) + float3(0.0, 0.0, t * 0.02)) - 0.5) * swirl * 0.9;
        float bands = 0.5 + 0.5 * sin((lat + warp) * bandCount * M_PI_F);
        float contrast = mix(0.35, 1.1, swirl);
        bands = saturate((bands - 0.5) * (1.0 + contrast) + 0.5);
        // Latitude bands are circles that pinch to a point at each pole ("beach-ball"
        // artifact). Fade them into a smooth, uniform polar hood so nothing converges.
        float polar = smoothstep(0.70, 0.96, fabs(lat));
        bands = mix(bands, 0.5, polar);
        float3 c = mix(base, detail, bands);
        c = mix(c, mix(base, detail, 0.4) * 1.05, polar * 0.5);                 // subtle polar hood
        // Fine turbulent filaments stretched along the bands (higher resolution),
        // themselves faded at the poles so they don't reintroduce the pinch.
        c = mix(c, detail, fbm6(dir * float3(4.0, 24.0, 4.0) + sd * 5.0) * 0.20 * contrast * (1.0 - polar));
        // A seeded "great spot" storm oval, more prominent on swirlier giants.
        float3 sc = normalize(float3(cos(r2 * 6.283), (r3 - 0.5) * 0.9, sin(r2 * 6.283)));
        float storm = smoothstep(0.24, 0.02, distance(dir, sc)) * (0.3 + 0.7 * swirl);
        c = mix(c, mix(detail, float3(0.85, 0.5, 0.4), 0.5) * 1.15, storm * 0.85);
        s.albedo = c;
    } else if (style == 6) {                     // ICE GIANT — near-featureless, few crisp spots
        // Mostly uniform methane tint with two or three very broad, soft bands,
        // faded at the poles so the faint banding doesn't pinch to a point.
        float bands = 0.5 + 0.5 * sin(lat * mix(2.0, 4.0, r0) * M_PI_F);
        bands = mix(bands, 0.5, smoothstep(0.70, 0.96, fabs(lat)));
        float3 c = mix(base, mix(base, detail, 0.5), bands * 0.22);
        // A small number of well-defined discrete dark/bright spots (Neptune-like).
        float spots = 0.0;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float3 sc = normalize(float3(cos(pr(sd, 30.0 + fi) * 6.283),
                                         (pr(sd, 40.0 + fi) - 0.5) * 1.2,
                                         sin(pr(sd, 30.0 + fi) * 6.283)));
            spots = max(spots, smoothstep(0.13, 0.03, distance(dir, sc)) * (fi == 0.0 ? 1.0 : pr(sd, 50.0 + fi)));
        }
        s.albedo = mix(c, detail, spots * 0.7);
    } else if (style == 2) {                     // icy — bright, fractured, polar caps
        float3 c = mix(base, detail, nHi * 0.5);
        float frac = ridge(dir * 7.0 + sd * 5.0);
        c = mix(c, float3(1.0), smoothstep(0.72, 1.0, frac) * 0.5);             // sharp fracture glints
        c = mix(c, float3(0.95, 0.97, 1.0), smoothstep(0.6, 0.95, fabs(lat)) * 0.6); // caps
        s.albedo = c;
    } else if (style == 3) {                     // molten — dark crust + glowing cracks
        // `mods.z` (lava×) carries temperature × tag intensity: hotter worlds crack
        // wider AND glow brighter, cooler ones show only thin, dim seams. `detail` is
        // the black-body lava hue the CPU chose from the surface temperature.
        s.albedo = mix(base * 0.55, base, fbm6(dir * 5.0 + sd * 7.0));
        float lavaAmt = mods.z;
        float lo = mix(0.80, 0.60, saturate((lavaAmt - 0.5) / 1.3));            // more lava when hotter
        float cracks = smoothstep(lo, lo + 0.17, ridge(dir * 8.0 + sd * 3.0));
        float pulse  = 0.7 + 0.3 * sin(t * 1.5 + lon * 3.0 + sd * 6.283);
        s.emissive = detail * cracks * pulse * 1.4 * clamp(lavaAmt, 0.5, 1.8);
    } else if (style == 4) {                     // ocean / terrestrial — continents (clouds below)
        float land = smoothstep(0.46, 0.6, fbm6(dir * 2.5 + sd * 10.0));
        float3 c = mix(base, detail, land);
        // Vegetation greens the land on a living world; saturate it by the CPU-supplied
        // `greenVibrancy` (livelier inside the habitable zone) so a high-life terran
        // world like SOL-3 reads vivid rather than washed out. Blue ocean is untouched.
        float3 veg = saturateColor(float3(0.24, 0.52, 0.28), greenVibrancy);
        c = mix(c, veg, land * life * 0.8);                                     // vegetation
        s.albedo = c;
        float cities = smoothstep(0.75, 0.88, fbm6(dir * 30.0 + sd * 8.0)) * smoothstep(0.6, 1.0, life) * land;
        s.emissive = float3(1.0, 0.85, 0.55) * cities * 1.1;                    // night-side lights
    } else if (style == 5) {                     // desert — wind-blown dunes
        // Dunes as anisotropic ridged noise (stretched ridges), NOT a longitude
        // sinusoid — a `sin(lon·N)` pattern draws meridian wedges that pinch to a
        // point at both poles (the "beach-ball" artifact) and seam at the antimeridian.
        float3 warp = dir + (fbm6(dir * 3.0 + sd * 6.0) - 0.5) * 0.25;          // meander the ridges
        float span = mix(7.0, 12.0, r0);
        float dunes = ridge(warp * float3(span, 3.0, span) + sd * 4.0);        // elongated, pole-safe
        float fine  = fbm6(dir * 20.0 + sd * 3.0) * 0.12;                       // grain
        s.albedo = mix(base, detail, saturate(dunes * 0.55 + fine));
    } else {                                     // rocky / barren — cratered mottle
        float3 c = mix(detail, base, fbm6(dir * 6.0 + sd * 4.0));
        float craters = smoothstep(0.62, 0.92, ridge(dir * 14.0 + sd * 9.0));
        s.albedo = mix(c, detail * 0.7, saturate(craters * 0.6 * mods.x));      // tags: deeper craters
    }

    // Temperature-driven polar ice caps — a ragged, high-albedo cap grows DOWN from
    // each pole as a cold world gets colder. `polarIce` (0…1) sets how far the ice
    // reaches toward the equator (its extent), NOT its opacity: the cap is always
    // rendered as solid ice, so even a small amount reads clearly. The CPU only sets
    // `polarIce` > 0 for cold desert/terran/ocean worlds; icy styles get 0.
    if (polarIce > 0.0) {
        // Latitude at which the ice begins: high (near the pole) for a small cap,
        // dropping toward the equator as the world gets colder (0.565 = the coldest
        // cap reaches ~75% as far as an unscaled 0.42 boundary would).
        float capLat = mix(0.92, 0.565, polarIce);
        float edge = fabs(lat) + (nHi - 0.5) * 0.15;                // noise-perturbed rim
        float cap = smoothstep(capLat, capLat + 0.06, edge);        // soft AA rim, full opacity within
        s.albedo = mix(s.albedo, float3(0.92, 0.96, 1.0), cap);
    }

    // Tag-driven frost/ice overlay — a cold, high-albedo dusting on any surface
    // (e.g. `ice_surface`/`frozen`/`cold` on a body that isn't typed icy).
    if (mods.w > 0.0) {
        float frostMask = smoothstep(0.45, 0.75, nHi);
        s.albedo = mix(s.albedo, float3(0.90, 0.95, 1.0), saturate(frostMask * mods.w));
    }

    // Animated cloud cover — terrestrial styles only (giants convey their skies in the
    // band texture, styles 1/6). Sampled along `cloudDir` (an elevated, faster-rotating
    // deck computed in the fragment), with two noise octaves boiling at different rates
    // so the cover morphs as it travels. Crucially, the scanned atmosphere thickness
    // (`mods.y`, ×`cloudAmount`) drives the coverage THRESHOLD — thin air shows only the
    // densest wisps; a crushing sky pulls the threshold below the noise floor so the deck
    // closes over the whole disc. All feel constants are baked above (`kCloud*`).
    if (style != 1 && style != 6 && mods.y > 0.0 && kCloudAmount > 0.0) {
        float freq = kCloudScale;
        float3 p0 = cloudDir * freq         + float3(0.0, 0.0, t * kCloudSpeed);
        float3 p1 = cloudDir * (freq * 0.5) + float3(t * kCloudSpeed * 0.5, sd * 2.0, 0.0);
        float cov = mix(fbm6(p0), fbm6(p1), 0.4);
        float density = saturate(mods.y * kCloudAmount / 1.3);              // 0 … 1 (crushing)
        float lo = mix(0.9, -0.2, density);                                 // coverage: fewer→all
        float hi = lo + max(kCloudSharpness, 0.02);
        float cloud = smoothstep(lo, hi, cov);
        s.albedo = mix(s.albedo, float3(1.0), saturate(cloud * kCloudOpacity));
    }
    return s;
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
    // Screen-space arc-length from endpoint A, in pixels. Interpolated WITHOUT
    // perspective correction (screen-linear) so a fragment's value is its true
    // pixel distance along the ribbon — that's what makes dashes uniform in screen
    // space even when the trajectory is foreshortened toward/away from the camera.
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
    // 0 at A, full screen length at B; screen-linear interpolation (see the varying)
    // turns this into the fragment's true pixel distance along the trajectory.
    out.screenDist = v.along * length(delta);
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

// ---------------------------------------------------------------------------
// Orrery — the system-focus scale: a lit sun + planets on flat orbital
// scaffolding, revealed when the camera flies into a system. Bodies are lit
// spheres that write depth (occlude correctly); rings/belt are additive chrome.
// All fade in with `u.orreryReveal`.
// ---------------------------------------------------------------------------

// Planets are billboard sphere-IMPOSTORS, not triangle meshes: a camera-facing
// quad whose fragment reconstructs the sphere normal from the disc coordinate —
// perfectly round at any zoom (no facets), and cheap. Lambert-lit by the sun (the
// focused star at `sunEmissive.xyz`). The sun itself is NOT drawn here — it's the
// persistent focused field star, so the star→sun transition is one object.
struct OrreryBodyVaryings {
    float4 position [[position]];
    float2 uv;           // [-1,1] across the disc
    float3 viewCenter;   // body centre in view space
    float  radius;       // body radius in view units
    float3 viewSun;      // sun position in view space (light)
    float3 color;        // base albedo
    float3 detail;       // secondary/terrain tint
    float  style;        // surface style index (cast to int in the fragment)
    float  life;         // biosphere strength (0…1)
    float  estimated;    // 0 = confirmed, 1 = provisional (duller + staticky)
    float  seed;         // per-body spin/longitude offset
    float  vseed;        // stable per-planet appearance seed (name+rotation hash)
    float  polarIce;     // temperature-driven polar ice caps (0…1)
    float  greenVibrancy; // saturation × for the world's green (land+vegetation); 1 = off
    float4 mods;         // tag-driven surface modifiers (crater×, cloud×, lava×, frost)
};

vertex OrreryBodyVaryings orrery_body_vertex(uint vid                       [[vertex_id]],
                                             constant Uniforms&              u    [[buffer(1)]],
                                             constant OrreryBodyUniform&     b    [[buffer(2)]])
{
    OrreryBodyVaryings out;
    float4 viewC = u.view * float4(b.centerRadius.xyz, 1.0);
    float radius = b.centerRadius.w;

    float2 corner = kCorners[vid];
    float4 viewPos = viewC;
    viewPos.xy += corner * radius;
    out.position = u.projection * viewPos;
    out.uv = corner;
    out.viewCenter = viewC.xyz;
    out.radius = radius;
    out.viewSun = (u.view * float4(b.sunEmissive.xyz, 1.0)).xyz;
    out.color = b.color.rgb;
    out.detail = b.detailColor.rgb;
    out.style = b.detailColor.w;
    out.estimated = b.surfaceParams.x;
    out.life = b.surfaceParams.y;
    out.seed = b.surfaceParams.z;
    out.vseed = b.surfaceParams.w;
    out.polarIce = b.color.a;
    out.greenVibrancy = b.sunEmissive.w;
    out.mods = b.surfaceMods;
    return out;
}

fragment float4 orrery_body_fragment(OrreryBodyVaryings in [[stage_in]],
                                     constant Uniforms&    u    [[buffer(1)]])
{
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();
    float nz = sqrt(saturate(1.0 - d * d));          // hemisphere z → sphere normal
    float3 nView = float3(in.uv, nz);
    float coverage = smoothstep(1.0, 1.0 - fwidth(d) - 0.01, d);   // soft AA limb

    // Reconstruct the real surface direction from the billboard: back-transform the
    // view-space hemisphere by the inverse (transpose) view rotation, then spin it
    // slowly about the pole so the texture rotates rather than being pinned to the
    // camera (mirrors star_body_fragment's granulation parallax).
    float3x3 viewRot = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3 dir = normalize(transpose(viewRot) * nView);
    float spin = u.time * 0.06 + in.seed;
    float cs = cos(spin), sn = sin(spin);
    dir = float3(dir.x * cs - dir.z * sn, dir.y, dir.x * sn + dir.z * cs);

    // The cloud deck: an elevated layer that rotates FASTER than the surface, so the
    // weather visibly travels across the planet. `cloudHeight` shifts the sample toward
    // the viewer tangentially (growing toward the limb) so the deck reads as floating
    // above the terrain — a cheap parallax that pairs with the halo's shell gap. The
    // extra `cloudDrift` rotation is added on top of the surface spin.
    float3 toCam = float3(0.0, 0.0, 1.0);                      // distant-camera view dir (view space)
    float3 tang = toCam - dot(toCam, nView) * nView;           // tangential to the sphere here
    float3 nViewCloud = normalize(nView - tang * kCloudHeight);
    float3 cloudDir = normalize(transpose(viewRot) * nViewCloud);
    float cspin = spin + u.time * kCloudDrift;
    float ccs = cos(cspin), csn = sin(cspin);
    cloudDir = float3(cloudDir.x * ccs - cloudDir.z * csn, cloudDir.y, cloudDir.x * csn + cloudDir.z * ccs);

    OrrerySurface surf = orrerySurface(dir, cloudDir, int(in.style + 0.5), in.color, in.detail,
                                       in.life, in.mods, in.polarIce, in.greenVibrancy, in.vseed, u.time);

    float3 fragView = in.viewCenter + nView * in.radius;
    float3 L = normalize(in.viewSun - fragView);
    float diff = max(dot(nView, L), 0.0);
    // Ambient + lambert on the albedo; emissive (lava / city lights) added on top,
    // weighted toward the night side so it reads as self-illuminated.
    float3 lit = surf.albedo * (0.14 + 1.05 * diff) + surf.emissive * (0.4 + 0.6 * (1.0 - diff));

    // Estimated bodies (partial recon): drain the colour toward grey and overlay a
    // restless static/scanline flicker — the surface reads as provisional, not solid.
    if (in.estimated > 0.5) {
        float g = dot(lit, float3(0.299, 0.587, 0.114));
        lit = mix(lit, float3(g), 0.55) * 0.82;
        float stat = hash13(float3(floor(in.position.xy), floor(u.time * 14.0)));
        float scan = 0.5 + 0.5 * sin(in.position.y * 0.6 + u.time * 6.0);
        lit *= mix(0.7, 1.08, stat) * mix(0.9, 1.0, scan);
    }
    return float4(lit, coverage * u.orreryAlpha);
}

// Atmosphere halo — a soft glow shell that bleeds beyond a terrestrial body's limb
// into space. Drawn AFTER the opaque bodies in a separate additive, depth-READ pass,
// so a nearer body occludes it but it never writes depth. The quad is enlarged past
// the body radius by the shell `extent`; the solid planet occupies the inner disc
// (d ≤ sphereFrac) and is skipped — only the outer ring is emitted, brightest at the
// limb and fading to nothing at the shell edge, weighted toward the sunlit side.
struct OrreryAtmoVaryings {
    float4 position [[position]];
    float2 uv;          // [-1,1] across the enlarged shell quad (d=1 at shell edge)
    float  sphereFrac;  // body radius / shell radius → where the solid planet ends
    float3 tint;        // glow colour
    float  density;     // opacity/intensity (0…1)
    float2 sunDir;      // sun direction in the screen plane (0,0 = along view axis)
};

vertex OrreryAtmoVaryings orrery_atmosphere_vertex(uint vid                          [[vertex_id]],
                                                   constant Uniforms&                 u    [[buffer(1)]],
                                                   constant OrreryAtmosphereUniform&  a    [[buffer(2)]])
{
    OrreryAtmoVaryings out;
    float4 viewC = u.view * float4(a.centerRadius.xyz, 1.0);
    float bodyRadius  = a.centerRadius.w;
    float shellRadius = bodyRadius * a.sunExtent.w * kHaloExtent;

    float2 corner = kCorners[vid];
    float4 viewPos = viewC;
    viewPos.xy += corner * shellRadius;
    out.position = u.projection * viewPos;
    out.uv = corner;
    out.sphereFrac = shellRadius > 0.0 ? bodyRadius / shellRadius : 1.0;
    out.tint = a.tintDensity.rgb;
    out.density = a.tintDensity.w;

    float3 viewSun = (u.view * float4(a.sunExtent.xyz, 1.0)).xyz;
    float2 sd = viewSun.xy - viewC.xyz.xy;
    float sdLen = length(sd);
    out.sunDir = sdLen > 1e-4 ? sd / sdLen : float2(0.0);
    return out;
}

fragment float4 orrery_atmosphere_fragment(OrreryAtmoVaryings in   [[stage_in]],
                                           constant Uniforms&    u    [[buffer(1)]])
{
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();

    // Only the ring outside the solid planet; fade in across the limb for AA.
    float aa = max(fwidth(d), 1e-4);
    float limb = smoothstep(in.sphereFrac - aa, in.sphereFrac + aa, d);

    // Brightest at the limb, decaying to zero at the shell's outer edge.
    float span = max(1.0 - in.sphereFrac, 1e-3);
    float t = saturate((d - in.sphereFrac) / span);
    float radial = pow(1.0 - t, kHaloFalloff);

    // Sunlit side glows more; when the sun is ~along the view axis the whole rim lifts.
    float day = 1.0;
    if (dot(in.sunDir, in.sunDir) > 1e-6) {
        float2 rim = d > 1e-4 ? in.uv / d : float2(0.0);
        day = (1.0 - kHaloDayWeight) + kHaloDayWeight * saturate(dot(rim, in.sunDir));
    }

    float glow = limb * radial * day * in.density * kHaloDensity * u.orreryAlpha;
    return float4(in.tint * (glow * kHaloIntensity), 1.0);
}

// Scaffold lines — orbit rings, HZ band, kuiper — additive, faded by reveal.
struct OrreryLineVaryings {
    float4 position [[position]];
    float4 color;
};

vertex OrreryLineVaryings orrery_line_vertex(uint vid                      [[vertex_id]],
                                             const device OrreryLineVertex*  verts [[buffer(0)]],
                                             constant Uniforms&              u     [[buffer(1)]])
{
    OrreryLineVaryings out;
    // Grow out of the star in step with the planets (same `orreryReveal`).
    float3 local = verts[vid].position.xyz - u.orreryCenter.xyz;
    float3 world = u.orreryCenter.xyz + local * u.orreryReveal;
    out.position = u.projection * (u.view * float4(world, 1.0));
    out.color = verts[vid].color;
    return out;
}

fragment float4 orrery_line_fragment(OrreryLineVaryings in [[stage_in]],
                                     constant Uniforms&    u [[buffer(1)]])
{
    return float4(in.color.rgb * (in.color.a * u.orreryAlpha), 1.0);
}

// Asteroid belt — additive point ring, faded by reveal.
struct OrreryPointVaryings {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;
};

vertex OrreryPointVaryings orrery_point_vertex(uint vid                    [[vertex_id]],
                                               const device AmbientVertex*   pts [[buffer(0)]],
                                               constant Uniforms&            u   [[buffer(1)]])
{
    OrreryPointVaryings out;
    AmbientVertex m = pts[vid];
    // Grow out of the star in step with the planets/rings (same `orreryReveal`), and
    // rotate the whole belt rigidly about the star (fixed 150 s period, CCW like the
    // planets and the sun's spin) so it drifts as one ring rather than sitting frozen.
    float3 local = m.positionSize.xyz - u.orreryCenter.xyz;
    float  ang   = -u.time * (2.0 * M_PI_F / 150.0);
    float  c = cos(ang), s = sin(ang);
    local = float3(local.x * c - local.z * s, local.y, local.x * s + local.z * c);
    float3 world = u.orreryCenter.xyz + local * u.orreryReveal;
    out.position = u.projection * (u.view * float4(world, 1.0));
    out.pointSize = clamp(m.positionSize.w, 1.0, 5.0);
    out.color = float4(m.color.rgb, m.color.a * u.orreryAlpha);
    return out;
}

fragment float4 orrery_point_fragment(OrreryPointVaryings in [[stage_in]],
                                      float2 pc              [[point_coord]])
{
    float d = length(pc - float2(0.5));
    float a = saturate(1.0 - d * 2.0);
    return float4(in.color.rgb * (in.color.a * a), 1.0);
}

// Body annotation pips — indicator dots + the pulsing incoming-asteroid marker.
// Billboarded at a constant pixel radius (with a screen-space cluster offset), so
// they hug the body at any zoom. Additive, faded by reveal; depth-read so a pip on
// a body behind the sun is occluded. The pip's depth is the body's projected depth.
struct OrreryPipVaryings {
    float4 position [[position]];
    float2 uv;        // [-1,1] across the dot
    float3 color;
    float  pulse;     // pulse speed (0 = steady)
};

vertex OrreryPipVaryings orrery_pip_vertex(uint vid                     [[vertex_id]],
                                           uint iid                     [[instance_id]],
                                           const device OrreryPip* pips [[buffer(0)]],
                                           constant Uniforms&      u    [[buffer(1)]],
                                           constant MeshParams&    p    [[buffer(2)]])
{
    OrreryPip pip = pips[iid];
    float2 corner = kCorners[vid];

    float4 clip = u.projection * (u.view * float4(pip.worldPosRadius.xyz, 1.0));
    // Billboard: a pixel-sized quad plus the cluster offset, both in pixels → NDC.
    float2 px = corner * pip.worldPosRadius.w + pip.pixelOffset;
    clip.xy += px * 2.0 / p.viewportPixels * clip.w;

    OrreryPipVaryings out;
    out.position = clip;
    out.uv = corner;
    out.color = pip.color.rgb;
    out.pulse = pip.color.a;
    return out;
}

fragment float4 orrery_pip_fragment(OrreryPipVaryings in [[stage_in]],
                                    constant Uniforms&   u [[buffer(1)]])
{
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();
    // Soft-edged filled dot with a small hot core.
    float aa = max(fwidth(d), 1e-4);
    float disc = 1.0 - smoothstep(1.0 - aa, 1.0, d);
    float core = pow(saturate(1.0 - d), 3.0);
    // Pulse: an incoming-asteroid marker breathes faster as the deadline nears.
    float pulse = in.pulse > 0.0 ? mix(0.45, 1.0, 0.5 + 0.5 * sin(u.time * in.pulse)) : 1.0;
    return float4(in.color * ((disc + core) * u.orreryAlpha * pulse), 1.0);
}
