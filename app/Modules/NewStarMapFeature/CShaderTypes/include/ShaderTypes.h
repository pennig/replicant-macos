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
} Uniforms;

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
    float dashPeriod;       // dashes along the not-yet-travelled remainder
} ShipParams;

// Per-label params for the text-quad pass (all in pixels, top-left origin).
typedef struct {
    simd_float2 originPx;    // top-left of the label rect
    simd_float2 sizePx;      // label size
    simd_float2 viewportPx;  // drawable size
    float opacity;           // fade in/out (0…1)
    float _pad;
} LabelParams;

#endif /* ShaderTypes_h */
