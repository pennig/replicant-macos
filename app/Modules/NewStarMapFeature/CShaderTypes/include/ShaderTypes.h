#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Single source of truth for the CPU<->GPU memory layout.
// Include this from the .metal file AND from the Swift bridging header so the
// struct layouts can never drift apart.

// Static per-star data. Uploaded once; never touched again on the hot path.
// Splitting *static* geometry from the *dynamic* relevance channel (a separate
// buffer, below) is deliberate: overlays only ever rewrite the small relevance
// buffer, not this.
typedef struct {
    // xyz = world position, w = world-space radius (drives size-encodes-depth).
    simd_float4 positionRadius;
    // rgb = spectral color, a = reserved.
    simd_float4 color;
} StarInstance;

// A single mote of the interstellar medium — dust haze, nebula gas, a proto-star
// glint, or a distant star-shell point. The stuff *between* the charted systems,
// baked into one additive point-sprite buffer drawn behind the field.
typedef struct {
    // xyz = world position, w = point size in pixels.
    simd_float4 positionSize;
    // rgb = tint, a = brightness.
    simd_float4 color;
} AmbientVertex;

// One soft "puff" of a nebula cloud — a WORLD-SPACE billboard (unlike AmbientVertex,
// whose w is a fixed pixel size). Because its radius is in world units it projects
// with depth and parallaxes as a real volume; many overlapping puffs read as diffuse
// gas. The cloud's SHAPE comes from how the puffs are distributed (see NebulaField),
// not from the individual sprite. Generated on the CPU by NebulaField and fed to the
// live nebula pass in StarFieldRenderer.
typedef struct {
    simd_float4 positionSize;   // xyz = world position, w = world-space radius (ly)
    simd_float4 color;          // rgb = tint, a = per-puff opacity (pre-accumulation)
} NebulaPuff;

// Live render knobs for the nebula pass in the REAL star map (StarFieldRenderer),
// where the camera comes from the shared `Uniforms` (so nebulae recede + fade with a
// system drill-in) and only these per-frame scalars need their own buffer. Kept a
// multiple of four for 16-byte alignment.
typedef struct {
    float sizeScale;    // global puff size multiplier
    float brightness;   // global opacity multiplier
    float softness;     // radial falloff exponent (higher = softer, wispier edges)
    float saturation;   // color saturation (1 = as generated)
    float coreBoost;    // extra brightness at each puff's dense center
    float _pad0;
    float _pad1;
    float _pad2;
} NebulaRenderParams;

// Frame uniforms.
typedef struct {
    simd_float4x4 view;
    simd_float4x4 projection;

    // Sprite sizing band (angular, radians-ish in view space). The floor keeps
    // distant stars from vanishing sub-pixel at overview; the ceiling caps
    // near-field fill so one close star can't balloon across the screen.
    float minAngularSize;
    float maxAngularSize;

    // Atmospheric depth attenuation. A per-frame, camera-relative cue — kept
    // OUT of the relevance buffer on purpose. Far stars dim toward atmoFloor.
    float atmoNear;   // distance at/under which brightness is full
    float atmoFar;    // distance at/over which brightness hits the floor
    float atmoFloor;  // minimum brightness for depth dimming (never fully black)

    float exposure;   // global tone-map exposure for the whole field

    // Sphere/disc LOD, driven by a star's on-screen angular size (radius/dist):
    // below lodStart it's a soft glow sprite; above lodFull it's a luminous disc;
    // between, a cross-fade so there's no pop across the field (one state machine
    // with the size band above — geometric LOD == semantic-zoom tier).
    float lodStart;
    float lodFull;

    float time;       // seconds, for surface animation (granulation spin)

    // System-focus (orrery) blend. `fieldDim` fades the galaxy field + ambient as
    // the camera flies into a system (1 = full galaxy, 0 = hidden); `orreryReveal`
    // ramps the orrery in/out (0…1).
    float fieldDim;
    float orreryReveal;
    // System↔body crossfade (0 = system level, 1 = drilled into a planet). Drives
    // the drill from a system into one of its planets: the sibling planets + the
    // sun shrink and fade out as this ramps 0→1, leaving the focused planet and its
    // moons alone on empty space. Unwinds on zoom-out for free.
    float bodyReveal;
    // Orrery OPACITY, decoupled from `orreryReveal` (which drives the grow-out of
    // orbits/scaffold from the centre and must track each body's true position).
    // A drilling body cross-fade renders two orrery layers in one frame — the
    // departing system and the arriving body — each with the SAME `orreryReveal`
    // (fully grown) but its OWN `orreryAlpha`, so one fades out while the other
    // fades in without either collapsing toward the centre. At every other time
    // this equals `orreryReveal`.
    float orreryAlpha;
    // Galaxy-overlay opacity (FTL mesh, ship vectors, player/relay markers). These
    // belong to the overview and fade with the drill ASYMMETRICALLY, so the CPU
    // computes it (the shader can't see the transition direction): out fast over the
    // first half of a drill IN (reveal 0→0.5), then back in gently over the WHOLE
    // zoom OUT (reveal 1→0). 1 = full, 0 = hidden.
    float overlayDim;
    // System-focus recession. As the camera drills in (`orreryReveal` 0→1) the
    // background field is pushed radially away from the focused star and shrunk
    // toward pinpricks, so the amplified parallax reads as "flying in" rather than
    // the field merely fading. `systemPush` is the extra radial distance factor
    // (0 = no push); `fieldShrink` is the non-focused angular-size multiplier at
    // full focus (1 = unchanged, <1 = collapse to dust). The focused star (the
    // orrery sun) is exempt from both. Both unwind on zoom-out for free.
    float systemPush;
    float fieldShrink;
    // The drilled-in star's instance index (-1 = none). That star becomes the
    // orrery's sun: it never fades (kept at full `fieldDim`) and its angular-size
    // ceiling is lifted so it keeps growing as you zoom in — no separate sun body,
    // so the star→sun transition is the same object throughout.
    int focusedStar;
    // Orrery centre (world space) — the LIVE centre of the layer being drawn: the
    // focused star at system level, or the drilled planet at body level, where it
    // tracks that planet around its star every frame.
    simd_float4 orreryCenter;
    // The centre the orrery scaffold/belt buffers were GENERATED around. Scaffold
    // vertices are rebased by (orreryCenter − orreryBuildCenter) at draw time, so a
    // moving body-level centre never forces a per-frame buffer rebuild.
    simd_float4 orreryBuildCenter;
    // The pivot the background field recedes from — the FOCUSED STAR, always. Kept
    // separate from `orreryCenter` because at body level that centre tracks the
    // drilled planet as it orbits, and the star field must NOT be dragged along
    // with it (the recession pivot has to stay put or the whole sky slides).
    simd_float4 fieldCenter;
} Uniforms;

// One vertex of a lit orrery body mesh (sun / planet). The shared unit sphere,
// scaled + translated per body via OrreryBodyUniform. Normal == position on a
// unit sphere, so it survives uniform scale + translation.
typedef struct {
    simd_float3 position;
    simd_float3 normal;
} OrreryMeshVertex;

// Per-body params for one orrery sphere draw.
typedef struct {
    simd_float4 centerRadius;   // xyz = world center, w = radius
    simd_float4 color;          // rgb = base albedo, a = polar ice caps (0…1, temperature-driven)
    simd_float4 sunEmissive;    // xyz = sun world position (light), w = green saturation × (land+vegetation; 1 = off)
    // Procedural surface texturing (see orrery_body_fragment / PlanetMaterial).
    simd_float4 detailColor;    // rgb = secondary/terrain tint, w = surface style index
    // x = estimated (0/1 → duller + staticky), y = life (0…1 biosphere), z = spin
    // seed (per-body longitude offset), w = reserved.
    simd_float4 surfaceParams;
    // Tag-driven surface modifiers (see PlanetMaterial.SurfaceModifiers): x = crater
    // relief ×, y = cloud/atmosphere ×, z = lava emissive ×, w = frost overlay (0…1).
    simd_float4 surfaceMods;
    // Body orientation: xyz = the body's north pole as a unit vector in world space
    // (from its axial tilt), w = signed spin rate in rad/s (negative = retrograde;
    // 0 = tidally locked, which carries its orbit angle in surfaceParams.z instead).
    // The fragment textures in the frame this defines, so every latitude feature —
    // gas bands, polar hoods, ice caps — tilts with the body for free.
    simd_float4 spinAxis;
    // x = subsurface-ocean cryo-fracture amount (0…1), y = silhouette irregularity
    // (0 = smooth sphere; >0 chips the limb AND tilts the shading normal from ONE noise
    // sample, so the outline and the terminator agree), zw = the MID and SHORT semi-axes
    // of an irregular body's ellipsoid, as multiples of the radius. The three axes are
    // normalised to unit product, so the shader recovers the long one as 1/(z·w) and the
    // shape costs two floats. Meaningless — and never read — when y is 0.
    simd_float4 surfaceExtras;
} OrreryBodyUniform;

// Per-body params for one orrery atmosphere halo — a soft glow shell drawn in a
// separate additive, depth-read pass AFTER the opaque bodies, so it bleeds beyond the
// planet's limb into space (and is occluded by any nearer body). See
// orrery_atmosphere_fragment / PlanetMaterial.atmosphereShell.
typedef struct {
    simd_float4 centerRadius;   // xyz = world center, w = the SOLID body radius
    simd_float4 sunExtent;      // xyz = sun world position (light), w = shell outer radius (× body radius)
    simd_float4 tintDensity;    // rgb = glow tint, w = density (opacity/intensity 0…1)
} OrreryAtmosphereUniform;

// Per-body params for one ring annulus, drawn in the body's EQUATORIAL plane (the
// plane perpendicular to its axial-tilt pole). Alpha-blended and depth-READ after
// the opaque bodies, so the near hemisphere occludes the far half of the ring and
// the ring itself occludes nothing. See orrery_ring_{vertex,fragment}.
typedef struct {
    simd_float4 centerRadius;   // xyz = body world centre, w = body radius
    simd_float4 poleInner;      // xyz = body pole (unit), w = inner radius (× body radius)
    simd_float4 sunOuter;       // xyz = sun world position, w = outer radius (× body radius)
    simd_float4 tintSeed;       // rgb = ring tint, w = band seed
} OrreryRingUniform;

// One vertex of the orrery scaffold: orbit rings, HZ band, kuiper — colored line
// segments in world space, drawn additively.
typedef struct {
    simd_float4 position;   // xyz = world position, w unused
    simd_float4 color;      // rgba
} OrreryLineVertex;

// A small billboard annotation over an orrery body: an indicator dot (a device /
// salvage / mining / inventory / life feature on a planet) or the pulsing
// incoming-asteroid hazard marker. Billboarded at a constant pixel radius with a
// screen-space cluster offset, so several pips sit in a tidy row above the body.
typedef struct {
    simd_float4 worldPosRadius;  // xyz = body world position, w = pip radius (pixels)
    simd_float4 color;           // rgb = pip color, a = pulse speed (0 = steady)
    simd_float2 pixelOffset;     // screen-space offset from the projected center (px)
    simd_float2 _pad;            // 16-byte alignment
} OrreryPip;

// A single vertex of an FTL-link ribbon. Each link expands to a screen-space quad
// (6 vertices); the vertex shader offsets by `side` along the screen-perpendicular
// so links have real, pixel-constant thickness. `along` (0 at A, 1 at B) is here
// for future effects — dashes, gradients, flow — with no geometry change.
typedef struct {
    simd_float3 a;    // link endpoint A (world)
    simd_float3 b;    // link endpoint B (world)
    float side;       // -1 or +1: which side of the line this vertex sits
    float along;      // 0 at A, 1 at B
} MeshLineVertex;

// Per-draw params for the mesh overlay: screen-space sizing in pixels.
typedef struct {
    simd_float2 viewportPixels;  // drawable size, to size links/markers in pixels
    float halfWidthPixels;       // half the link thickness
    float nodeRadiusPixels;      // relay marker (ring) radius
} MeshParams;

// A marker billboarded on a point (player, relay, ship head). Additive.
typedef struct {
    simd_float3 position;   // world position
    simd_float3 color;
    float radiusPixels;     // MINIMUM screen-space radius (a pixel floor)
    float style;            // 0 = hollow ring, 1 = filled glow
    float worldRadius;      // star's world radius to encircle (0 = pure pixel size)
} StateMarker;

// Per-ship params for the trajectory ribbon.
typedef struct {
    simd_float3 color;
    float progress;         // 0..1 head position along the trajectory
    float halfWidthPixels;  // ribbon half-thickness
    float tailLength;       // fraction of the trajectory the fading tail spans
    float dashCyclePixels;  // one dash+gap cycle length in SCREEN pixels (see ship_line_fragment)
} ShipParams;

// Tuning knobs for the solar-flare playground (FlarePlayground.swift). Every value
// the production star_fragment bakes as a constant is exposed here as a live
// uniform so it can be driven from sliders; dial it in, then copy the winners back
// into Shaders.metal's constants. All scalars first (kept a multiple of four for
// 16-byte alignment), then the three colours.
typedef struct {
    float lod;             // simulated on-screen LOD (0 = glow, 1 = resolved disc)
    float discEdge;        // sphere radius within the sprite quad
    float spinRate;        // surface spin speed (rad/s scale), shared by disc + flares
    float intensity;       // additive flare intensity

    float baseFreq;        // slow noise-layer frequency (tongue count)
    float baseTimeScale;   // slow layer temporal drift
    float baseWeight;      // slow layer weight into tongue height
    float flickFreq;       // fast noise-layer frequency (flicker detail)

    float flickTimeScale;  // fast layer temporal drift (flicker speed)
    float flickWeight;     // fast layer weight into tongue height
    float heightPower;     // sharpen exponent (spiky vs. blobby)
    float tongueBand;      // smoothstep fill band along the tongue

    float radialFalloff;   // base→tip dimming
    float edgeFadeStart;   // where the sprite-edge fade begins
    float hotMix;          // star→hot-base colour mix
    float coolMix;         // star→cool-tip colour mix

    float discBrightness;  // disc look (context)
    float exposure;        // inline tone-map exposure
    float time;            // seconds, animation clock (set per frame)
    float aspect;          // drawable aspect, to keep the star circular

    float granTimeScale;   // disc granulation temporal drift (surface "boil" speed)
    float _pad0;           // (padding — keep the scalar count a multiple of four)
    float _pad1;
    float _pad2;

    simd_float4 starColor; // rgb star spectral colour
    simd_float4 hotColor;  // rgb hot near-limb tint
    simd_float4 coolColor; // rgb cool ember tip tint
} FlareParams;

// Per-label params for the text-quad pass (all in pixels, top-left origin).
typedef struct {
    simd_float2 originPx;    // top-left of the label rect
    simd_float2 sizePx;      // label size
    simd_float2 viewportPx;  // drawable size
    float opacity;           // fade in/out (0…1)
    float _pad;
} LabelParams;

#endif /* ShaderTypes_h */
