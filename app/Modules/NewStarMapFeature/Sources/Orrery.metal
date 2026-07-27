#include "ShaderCommon.h"

// ---------------------------------------------------------------------------
// Orrery — the system-focus scale: a lit sun + planets on flat orbital
// scaffolding, revealed when the camera flies into a system. Bodies are lit
// spheres that write depth (occlude correctly); rings/belt are additive chrome.
// All fade in with `u.orreryReveal`.
// ---------------------------------------------------------------------------

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
    // NOTE: deliberately no `lon = atan2(dir.z, dir.x)` here. Longitude is undefined
    // at both poles and discontinuous at the antimeridian, so ANY feature driven by
    // it converges into a beach-ball pinch at the poles and seams down one meridian.
    // Every style below uses 3D noise over `dir` instead. Don't reintroduce it.

    // Decorrelated per-planet look parameters + a small stable hue jitter so two
    // planets of the same type never look identical.
    float r0 = pr(sd, 1.0), r1 = pr(sd, 2.0), r2 = pr(sd, 3.0), r3 = pr(sd, 4.0);
    float3 hj = (float3(pr(sd, 5.0), pr(sd, 6.0), pr(sd, 7.0)) - 0.5) * 0.14;
    base   = saturate(base + hj);
    detail = saturate(detail + hj);
    s.albedo = base;

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
        // Coverage threshold. The hot floor is 0.72 (was 0.60) and the ramp is
        // narrower, so even a hellworld reads as seams in basalt rather than the
        // >50% flood the old band produced.
        float lo = mix(0.88, 0.72, saturate((lavaAmt - 0.5) / 1.3));            // more lava when hotter
        float cracks = smoothstep(lo, lo + 0.13, ridge(dir * 8.0 + sd * 3.0));
        // Breathe the glow from 3D NOISE, never longitude. The old
        // `sin(t + lon * 3.0)` drew three meridian wedges that converged at both
        // poles (the beach-ball artifact the banded / iceGiant / desert styles each
        // fix separately) and seamed at the antimeridian. Noise over the sphere
        // direction has neither a pole nor a seam, and it makes separate hot regions
        // pulse independently instead of as one rotating grille.
        float pulse  = 0.7 + 0.3 * sin(t * 1.5 + fbm6(dir * 2.3 + sd * 11.0) * 6.283);
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
