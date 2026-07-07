# Star Map — Design Rationale & Agent Handoff

This document hands off a native macOS star-map project to the next coding agent.
It exists because the code shows *what* was built but not *why*, and the "why" is
load-bearing: most of the decisions below were chosen against specific
alternatives, and several are invariants that later features must not quietly
violate. Read the Invariants section before making rendering or camera changes.

---

## 1. What we're building

A 3D star map for a game — a native Mac app (SwiftUI shell, Metal rendering),
targeting Apple Silicon / recent macOS. The map shows ~10,000 charted stars —
**the local bubble of *known* space around the player, not a whole galaxy.** The
true galaxy's shape is unknown; the surveyed region just happens to read as
roughly spherical, dense at the core and fading to an edgeless frontier you push
into to discover more. (Slice 1's original two-arm spiral was a placeholder and
has been replaced by this charted-sphere model.) The player uses it to:

- get an overview of the whole galaxy and its structure,
- select a star (or search one by name) and focus/dive into it,
- see connections between stars — an FTL comms mesh and trade routes — as
  toggleable overlays,
- read data about stars (life, resources, etc.),
- track their own position and any in-transit ships and their trajectories.

Travel between stars is a **direct point-to-point trajectory** (2 ly or 75 ly,
doesn't matter — a straight line), *not* movement constrained to the mesh. So
"plot a course" is fundamentally "frame two endpoints and reduce surrounding
noise," and pathfinding is not a core concern.

**Product stance, decided explicitly:** this is a **3D map first, a data-viz tool
second**. It is not a flight sim. The player fantasy is a commander studying a
star map and diving into systems, not a pilot free-flying between them.

---

## 2. The core mental model

Two ideas underpin everything. If you internalize only these, you'll make
choices consistent with the rest.

### The three-layer architecture

Everything on screen is one of three layers, and **they want opposite
treatments** — which is why trying to reason about "how much do I show" as a
single dial produces false tensions. Keep them distinct.

1. **Terrain — the stars.** Complete (all ~10k, always), static, always-on. This
   is the *space the game happens in*. You do not toggle it or thin it by
   relevance. It should recede and read as a legible whole.
2. **Reference overlays — mesh, trade routes, resource/life data.** Curated by
   nature, toggleable, on-demand. This is *context you consult and dismiss*.
   Toggling the mesh off doesn't hide the galaxy; the terrain never moved. You're
   changing which information layer is lit.
3. **State overlays — the player position, ships, their live trajectories.**
   Always visible, never dimmed, top of the visual hierarchy at every zoom level.
   This is *game state* ("what is happening right now"), not reference. It's the
   one thing that must never be lost behind a star. Note it's also **tiny** — a
   dozen elements — so it has effectively unlimited render budget. All the
   density anxiety is about terrain and reference; the layer you always watch is
   sparse and cheap.

### The relevance field — the rendering brain

Every focus behavior — select, search, plot a route, toggle the mesh, filter by
resource — is **the same operation: write a per-star relevance value.** The
terrain renderer reads that value to set brightness. This unifies control,
rendering, and interaction into one data structure.

- Relevance is a continuous 0..1 per star. Default 1.0 = plain terrain.
- Overlays *write* it. Terrain *reads* it. That's the whole contract.
- When multiple overlays are active, **max-combine** (a star lit by any active
  concern stays lit), and the **state tier clamps** its stars so they can never
  be dimmed below full, regardless of what a reference overlay wants. State
  always wins — a ship flying to a backwater keeps that backwater lit even with
  the mesh dimming everything else.
- Transitions **ease** (~200–300 ms). A hard snap of thousands of stars reads as
  a bug; eased, the same change reads as the map "focusing." This also aids
  comprehension — you *see* what stayed vs. left.
- De-emphasized terrain floors at **near-invisible, not zero.** Two reasons:
  depth (a fully black field collapses the galaxy's structure and kills
  parallax) and honesty (a star dimmed to nothing but still clickable is a lie
  about what you can touch).

**Design decision (liked, not yet required):** relevance can fall off by *graph
distance* from the focus — on-mesh star at 1.0, one jump off at ~0.5, two at
~0.25 — so the network reads as embedded in a galaxy that fades away from it
rather than stamped onto a dead field. Slice 1 uses spatial distance as a
stand-in; swap the metric when the mesh graph exists.

**Design decision:** overlays are allowed to **restyle the terrain**, not just
draw on top of it. When the FTL mesh is active, stars not on it recede to near
invisibility. (This is *why* attenuation, not blur, is the de-noising primitive —
see Invariants.)

---

## 3. Design decisions & rationale (decisions log)

Grouped by area. Each entry is a settled choice; the rationale is there so you
can extend consistently, and the "rules out" is there so you don't relitigate.

### Navigation & camera

- **Turntable, not free arcball.** Azimuth free; elevation clamped (symmetric
  **±80°**); persistent galactic "up." *Why:* comprehension needs a stable
  reference frame; the player must never roll or tumble into disorientation. The
  clamp is symmetric (not 0–85°) because the terrain is a sphere with no
  privileged plane — viewing from below is legitimate — and the 10° pole margin
  dodges the gimbal singularity and top/bottom-down vertigo. Full 6DOF is a
  liability for a map. *Rules out:* roll, exact pole views, arbitrary orientation.
- **Refocus is a re-aim, not a fly-to.** Selecting a star holds the eye where it
  is and pivots to look at it (deriving the orbit from fixed-eye → new pivot), so
  a nearby star only changes the tilt. A `maxFocusRadius` cap adds a blend: a star
  farther than the cap also glides the eye *inward along the viewing ray* (a
  zoom-toward), because holding the eye that far out would leave the star an
  unreadable dot. The cap is applied once, to the goal eye; the move then
  interpolates eye + pivot as endpoints, so a tilt-only re-aim holds the eye
  exactly fixed. Timing is a `smoothstep` (ease-in-out) over a **300–750 ms**
  duration that scales with the size of the change, weighting eye *position*
  movement over orientation swing — a reposition reads heavier than a pure tilt.
- **Logarithmic, radius-multiplying dolly.** *Why:* the overview→single-star
  distance range is enormous; linear zoom either crawls or teleports. This is the
  single most important feel decision — get it wrong and nothing else matters.
- **Movement speed scales with distance to pivot.** Panning and any free motion
  feel the same at every zoom level. Orbit sensitivity also falls off as the
  camera pulls back (full inside `orbitReferenceRadius`, ∝ 1/√radius beyond, floored
  at `orbitMinSensitivity`) — otherwise the whole field sweeps by uncontrollably
  far out, and you can't place a labelled star in the viewport.
- **Trackpad drives bounded gestures only.** Two-finger drag → orbit; pinch →
  dolly; shift+drag → pan. *Why:* a trackpad is great at bounded gestures and bad
  at sustained ones — classic FPS mouselook needs unbounded dragging and runs off
  the edge with no pointer-lock. *Consequence:* if a true free-fly mode is ever
  added, its *look* should be keyboard-driven, not trackpad-driven. (Free-fly is
  currently deprioritized.)
- **Semantic zoom, coupled to geometric zoom.** What a star *is* changes with
  scale: overview = labeled point in a density field; mid = star with hover
  label + filtered connections; close = full data panel, textured body, all its
  links. *Rules out:* treating zoom as purely moving the camera closer.

### Rendering

- **Complete terrain, curated annotation.** All 10k stars are always rendered and
  always selectable; labels/detail are the curated layer on top. *Why:* the
  player wants to see the whole galaxy's structure, which lives in *where stars
  cluster*, not in any one star. At overview, **density becomes the unit of
  perception**, not the individual star.
- **Size encodes depth, not importance.** With real (textured-sphere) bodies,
  perspective makes near ones big and far ones small for free. *Consequence you
  must respect:* size is therefore *spoken for* — it cannot also signal
  importance. At overview, the biggest thing on screen is just the nearest thing,
  not the capital world. So the overview's entire visual hierarchy rests on
  **brightness, color, glow, and labels** — which is exactly why relevance-driven
  dimming is the primary de-noising language, not a nice-to-have.
- **Size floors at a minimum angular size.** Honest perspective shrinks distant
  stars sub-pixel and they vanish — fatal for "see all the charted stars." So
  size-encodes-depth holds *within a working band*; past the floor, depth reverts
  to brightness/atmospheric attenuation/parallax. Near-field also gets a ceiling
  so one close star can't fill the view (also a fill-rate control).
- **Attenuation (dimming/desaturating), never blur, for de-noising.** *Why:*
  attenuation pushes things back while preserving *where and what* they are; blur
  erases identity and position. This map's whole job is comprehension, and a
  blurred star is one you can't read or click. *Rules out:* tilt-shift / DoF as a
  persistent navigation mode. DoF is allowed only (a) as a momentary cinematic
  effect during focus transitions / framed-route beauty shots, or (b) as a
  *selection cue* if the focal plane tracks the pivot's depth. Not as vibe.
- **Tone-map the accumulated field as a whole.** *Why:* the galactic center is
  the densest region and the one with the most structure; naive additive blending
  blows it out to a white blob and destroys exactly the structure you care about.
  Uniform dimming won't fix it (the problem is local density). This is the single
  thing separating a deep, structured galaxy from a spilled sugar bowl.
- **Additive blending is order-independent** → the dense terrain pass needs no
  depth buffer and no sorting. The scary-looking part is the easy part. (Discs/
  spheres up close will want a depth prepass; the far field won't.)
- **Color does work size can't.** Spectral class → color is simultaneously real
  astronomy and real data, and it gives the overview texture the eye can read
  even when every mark is the same clamped size. Cheapest structure available.
- **The surface is the data canvas.** Since size is depth, data (life, resources,
  magnitude, population) lives on the sphere's surface / emissive / halos /
  orbiting glyphs / the detail panel — not in size.

### Architecture

- **Geometric LOD tier == semantic-zoom tier.** Textured sphere ⇒ close ⇒ full
  data panel; disc ⇒ mid ⇒ hover label; floored sprite ⇒ overview ⇒ labeled dot.
  Build them as *one* distance-driven state, not a render-LOD chain and a
  separate semantic system that fire near each other — otherwise you get bugs
  where the body is detailed but the data's hidden, or vice versa.
- **Fill-rate is the cost, not star count.** 10k instanced sprites is trivial
  (Metal handles far more). The performance risk is *overdraw* from additive
  glows piling up in the dense core. Optimize by bounding overdraw (size clamps,
  density-aware attenuation), not by culling stars.
- **Ship trajectories get their own visual language.** They are few, directed,
  and state-loaded — the opposite of the dense, symmetric, stateless static mesh.
  A ship reads as *motion with a heading* (bright comet head at current position,
  fading tail, dashed remainder toward destination), additive and glowing through
  the field, never dimmed or occluded. Do not let them inherit the faint-static-
  line treatment of trade routes.

### Framework choice

- **Raw Metal.** *Why not SceneKit:* soft-deprecated as of WWDC 2025 / macOS 26,
  maintenance-only. *Why not RealityKit:* entity-per-object with no material
  instancing (each object a draw call), known to struggle at tens of thousands of
  objects — that's our terrain layer described as a bug report. *Why Metal
  positively:* the relevance field *is* a data-oriented GPU design (per-instance
  buffer written by overlays, read by a shader); Metal is the only option where
  that's the native idiom rather than a fight. MetalSprockets (schwa) was
  considered and set aside for the core (pre-1.0, single-maintainer dependency
  risk) — fine for experiments behind an abstraction, not for the foundation.

---

## 4. Current state

A runnable macOS SwiftUI + Metal app, well past the original Slice 1. Builds and
runs; **51 Swift Testing tests pass** (logic is unit-tested — galaxy generation,
relevance combine/clamp/mask, camera framing/dolly/orbit, label collision, data
filters, status symbols, ship math). Working end to end: 10k instanced stars,
turntable camera with eased re-aim/dive + distance-relative controls, HDR +
tone-map, the relevance field driven by three writers (click-focus, FTL mesh, data
filters) with the state-tier clamp, glow→disc→granulated-sphere LOD with a depth
prepass for occlusion, ship trajectories + player reticle, and curated labels with
an SF-Symbol status row. Controls are in the file-map row for `MetalStarView`.

**World coordinates & data model.** A star's position is an xyz coordinate in
**light years with Sol at the origin** — so the world unit *is* 1 ly and (0,0,0)
is home. `Star` (in `Star.swift`) is the game-data source of truth: position,
temperature (K), `StellarClass` (O B A F G K M), and age (Myr, capped by
main-sequence lifetime). Rendering is *derived* from it — on-screen color comes
from temperature (a blackbody fit), and the GPU `StarInstance` is a projection of
a `Star`, never the other way around. Size stays a small depth-jitter and never
encodes class/importance (Invariant 5). `Star` also carries per-system game data:
`hasFTLRelay`, `life` (`LifeLevel`), `resources` (`Resources`), `scan`
(`ScanState`), `hasInventory` — all procedural stand-ins here; the game supplies
real values.

File map:

| File | Role |
|---|---|
| `StarMapApp.swift` | App entry + SwiftUI host (`ContentView`). |
| `MetalStarView.swift` | `NSViewRepresentable` + `MTKView` subclass. The trackpad-native input layer: scroll→orbit, shift+scroll→pan, pinch→dolly, click→pick+re-aim, double-click→dive, esc→clear, H→home, M→toggle FTL mesh, F→cycle data filters, G→toggle label symbols. |
| `StarFieldRenderer.swift` | `MTKViewDelegate`. Two pipelines, HDR target, per-frame draw, CPU screen-space star picking. All tunables live here. |
| `RelevanceField.swift` | The dynamic per-star relevance buffer with eased transitions. The rendering brain. Emphasis writers (`focus`, `mesh`) MAX-combine; a data `filter` MASKS the result; the state clamp pins player/ships to full. |
| `FTLMesh.swift` | The FTL comms mesh: proximity graph over relay-equipped systems (nodes + ≤7.5 ly links), its quad-ribbon link geometry, relay marker positions, and its per-star relevance contribution. First reference overlay / non-click relevance writer. |
| `Ship.swift` | A ship in transit: two endpoint systems + a time→progress/position along the direct trajectory. State-tier data. |
| `Selection.swift` | The `@Observable` current selection + the SwiftUI `StarDetailPanel` (name/class/temp/age/distance). |
| `DataFilter.swift` | Data-filter overlays (life / minerals / gas / rare / unexplored): turn per-system data into a relevance contribution. A relevance writer, like the mesh. |
| `LabelEngine.swift` | Pure screen-space label layout: priority-ordered greedy placement with collision rejection. The label subsystem's brain (no text, no GPU). |
| `LabelTextureCache.swift` | Rasterizes a label (name + white SF-Symbol status row, variable rendering for the resource gauge) to a cached Metal texture via Core Text, with a dark halo. |
| `Shaders.metal` | The passes into the HDR target: glow field (additive), opaque resolved discs (depth, granulated), mesh links, ship trajectories, state markers, glyph — then a tone-map pass and a label pass to the drawable. |
| `ShaderTypes.h` | Shared Swift/Metal struct layout (single source of truth; include via bridging header + `#include` in the .metal). |
| `TurntableCamera.swift` | Turntable state + gestures: free azimuth, ±80° elevation, log dolly (with a focus floor), distance-scaled pan, distance-relative orbit sensitivity, and the eased re-aim/dive/overview framing (injected clock). |
| `Star.swift` | The star + per-system domain model (`Star`, `StellarClass`, `LifeLevel`, `ScanState`, `Resources`, `StatusSymbol`) — source of truth. Position in ly from Sol; temperature→color and the GPU `renderInstance` projection; `statusSymbols`. |
| `Galaxy.swift` | Procedural generator: the charted-sphere distribution of `Star`s (position/class/temp/age + relay/life/resource/scan/inventory) from three deterministic RNG streams. |
| `Math.swift` | RH perspective (Metal z∈[0,1]) + look-at + a `SIMD4.xyz` swizzle. |
| `README.md` | Xcode setup (bridging header), controls, tunables, status notes. |

---

## 5. Invariants — do not break these

Quick-reference for anyone touching rendering or camera. Each traces to a
rationale above.

1. **Overlays write relevance; terrain reads it.** Don't push per-star state
   through anything else. New overlays = new writers to `RelevanceField`.
2. **State-tier stars (player/ships) never dim.** Whatever combine logic you add,
   clamp these to full. Losing a ship behind a star is the one unforgivable
   failure.
3. **De-noise by attenuation, never blur.** Positions and identity must survive
   de-emphasis (stars stay legible and clickable). DoF only for focus-moments or
   focal-plane-tracks-pivot selection, never as persistent mode.
4. **Relevance floors near-invisible, not zero.** Preserves depth and honest
   click targets.
5. **Size means depth, not importance.** Don't reintroduce size-as-importance; it
   fights perspective. Importance lives in brightness/color/labels.
6. **Turntable constraints hold.** Elevation clamped (symmetric ±80°, off the
   poles), galactic up persistent, no roll. The clamp widened from 0–85° once the
   terrain became a sphere and refocus became a re-aim — but bounded elevation +
   persistent up + no roll are the invariant; don't remove them or "free up" the
   camera to full 6DOF for convenience.
7. **Dolly and free-movement speed stay logarithmic / distance-relative.** Never
   linear.
8. **Tone-map the field as a whole; keep additive order-independent.** Don't add a
   depth buffer to the dense terrain pass "just in case" — it's not needed and
   the sort is the expensive thing you're getting for free. (There IS now a depth
   buffer, but ONLY on the separate opaque resolved-body pass + as a read-test on
   overlays; the dense additive glow pass still has no depth. Keep it that way.)
9. **LOD and semantic detail are one state machine**, not two.

---

## 6. Known gaps & placeholders

- ~~**Focus snaps the pivot.**~~ *Done.* Refocus now eases as a re-aim (holds the
  eye, pivots to the star) with a `maxFocusRadius` blend that zooms toward distant
  stars. Remaining nuance: near an elevation pole the derived tilt clamps, so a
  star almost directly above/below the eye lands near the view edge rather than
  dead-centre, and the eye shifts slightly in that edge case.
- **Sphere↔disc LOD landed** (glow → luminous disc). The **open question is
  settled: a map star is a LUMINOUS PRIMARY** (the star is the light source, so the
  near look is a limb-darkened self-luminous disc + corona — no external light
  direction). Driven by on-screen angular size (`radius/dist`) cross-faded across
  `lodStart…lodFull` in the star shader — the *same* distance state as the size
  band (Invariant 9), so no hard swap / field-wide pop. Still additive, no depth
  buffer (Invariant 8). The near disc has **procedural granulation** (3D value
  noise over the front hemisphere, foreshortened toward the limb, stronger on cool
  stars, gated by lod). The surface **animates** (slow spin via the `time` uniform)
  and is **view-coupled**: granulation is sampled in the star's WORLD space (view-
  space hemisphere point transformed back by the inverse view rotation), so
  orbiting reveals different surface — real sphere parallax, not a camera-locked
  decal. **Occlusion landed** (the depth prepass the artifact triggered): resolved
  discs render in a *separate* opaque, over-blended pass that WRITES depth, so they
  cover the field behind them and depth-sort against each other; the additive glow
  pass stays depth-less (Invariant 8). Overlays (mesh, relay/player reticles, ship
  trajectories) read-test depth → occluded behind a nearer body; **ship head
  markers are the sole exception** (no depth test — never lost behind a star, per
  Invariant 2, and the future always-on-top ship icon). Only sufficiently resolved
  (`lod`) and relevant (`brightness ≥ 0.4`) stars become solid bodies — receded
  ones stay glows, so a dim star never occludes a bright one. Remaining: real
  *texture* (spots/faculae) beyond granulation; lit *worlds/planets* post-dive.
- **System status symbols under the label** (toggle: G) — the on-surface glyph
  experiment was removed (noisy); system data now reads as a compact row of white
  **SF Symbols** beneath the name: exploration (`circle` / `circle.lefthalf.filled`
  / `circle.fill`), life (`leaf.fill`), resource richness (a **variable-rendered
  gauge**, `dollarsign.gauge.chart.leftthird.topthird.rightthird`, filled 0–100% by
  richness), stored inventory (`shippingbox.fill`). Life/resources/inventory only
  show once surveyed (unexplored → just the open circle). `Star.statusSymbols`
  returns `[StatusSymbol]` (name + optional 0…1 variable value; pure, tested);
  `LabelTextureCache` tints them white (palette config), uses SF Symbols' variable
  rendering where a value is present, and composites them as a row below the name — so
  they inherit label placement, collision, fade and screen-space drawing for free.
  `hasInventory` is a stand-in per-system flag on `Star`.
- **Overlays: FTL mesh landed** (toggle: M) — the first reference overlay and the
  first non-click relevance writer, proving max-combine (mesh + focus stay lit
  together). Model matches the game: nodes are relay-equipped systems, links join
  relay pairs ≤ 7.5 ly apart (a proximity graph), so orphans and disconnected
  sub-networks are expected — relays are drawn as ring markers so a lone relay is
  still visible. Links are **quad ribbons** (screen-space thickness via
  `MeshLineVertex.side`, with `along` reserved for dashes/gradients/flow) — not
  1px line primitives — so those effects are shader-only later. Off-mesh falloff
  is spatial to the nearest relay (position-based, so it's independent of where
  the mesh sits). Stand-in only: relay membership is assigned procedurally in
  `Galaxy` (`relayFraction`); the game passes real per-system state.
- **Overlays: state tier landed** — player + ships (HANDOFF §2 tier 3), always on,
  never dimmed. This finally exercises the **state-tier clamp** (Invariant 2):
  `RelevanceField.setStateClamp` pins the player system and every ship endpoint to
  full relevance *after* the max-combine — a clamp, not a writer, so it never dims
  the field when it's the only active concern. Ships render in their own language
  (comet head + fading tail + dashed remainder, `ship_line`/`state_marker`
  shaders), additive and never relevance-read. Stand-in: player = system nearest
  Sol, two looping demo ships; the game supplies real player/fleet state. Still to
  come: trade routes, resource/life data, labels, search.
- **On-surface data: filter overlays landed** (cycle: F) — systems carry life
  level, resource abundances (minerals/gas/rare) and scan state (`Star`,
  procedural stand-in in `Galaxy`). Surfaced as toggleable data filters
  (`DataFilter`) that write the relevance field (matching systems lit, rest
  recede), max-combined with mesh/focus — plus the fields in the detail panel and
  a HUD chip for the active filter. Deferred: literal *on-the-surface* encoding
  (halos / orbiting glyphs) waits for resolved bodies (sphere↔disc LOD); life
  could also correlate with habitable-zone class rather than being independent.
- **Label system landed** — focus+context annotation over the complete field:
  the selected star + the nearest on-screen systems, with priority-ordered
  screen-space collision avoidance (`LabelEngine`, pure + tested), centred just
  below each star (clear of its reticle-ring radius). Label count is **zoom-gated**
  (0 fully out → `maxContextLabels` fully in) and labels **fade** in/out (per-star
  eased opacity) so they don't snap. Rasterized once via Core Text into cached
  textures (`LabelTextureCache`), drawn *after* tone-map (never dimmed). Gaps:
  search-hit isn't a label source yet (no search); no leader lines / side
  selection; names are a procedural stand-in (`Galaxy.makeName`, separate stream).
- **Picking disambiguation.** Slice 1 picks nearest within a pixel radius; at
  overview, dozens overlap under the cursor — needs hover-cycling / zoom-to-
  disambiguate / radial pick menu.
- **Continuous 120fps redraw** wastes battery for a mostly-static map. Switch to
  `enableSetNeedsDisplay` + redraw-on-input, keeping continuous frames only while
  relevance is easing (`RelevanceField.step()` already returns that flag).
- **No bloom.** A small bloom on the HDR target before tone-map buys a lot of the
  "field of light" feel.

---

## 7. Next step — integration into the game (READ THIS)

**Status change:** this prototype is being ported into the game's own codebase,
which already has a rough **SceneKit** star-map implementation. The next agent's
job is integration, not more features here. Notes:

- **The prototype's value is the design + the pure logic, not the Metal renderer.**
  Everything worth carrying over is plain Swift with no Metal dependency and is
  unit-tested — port these largely as-is:
  - `Star.swift` (domain model incl. `statusSymbols`), `Galaxy.swift` (generation),
    `FTLMesh.swift` (proximity graph + relevance contribution), `DataFilter.swift`,
    `RelevanceField.swift` (the combine/mask/clamp brain — the buffer upload is the
    only Metal bit; the `combined`/mask/clamp math is portable), `LabelEngine.swift`
    (screen-space collision), `Ship.swift`, `TurntableCamera.swift` (pure value
    type; the whole camera feel lives here), and `Math.swift`.
  - The 51 tests move with them and are the safety net for the port.
- **Metal-specific, will NOT drop into SceneKit directly:** `Shaders.metal`,
  `ShaderTypes.h`, `StarFieldRenderer.swift`, `LabelTextureCache` (Core Text→MTLTexture),
  `MetalStarView`. These encode *how* the design renders; SceneKit needs its own.
- **SceneKit tension (see §3 "Framework choice"):** this project chose raw Metal
  *because* the relevance field is a per-instance buffer written by overlays and
  read by a shader, and because 10k discrete SceneKit nodes is the anti-pattern the
  rationale calls out. Before committing to SceneKit for the terrain, weigh: (a) the
  10k-node draw-call cost, and (b) how to express the relevance field — options are
  an `SCNGeometrySource`/per-instance attribute + an `SCNProgram`/shader modifier
  reading it, OR hosting this Metal terrain pass inside the SceneKit scene (SceneKit
  can composite with a Metal layer). If SceneKit can't carry the relevance-field
  idiom cheaply, that's the signal to keep terrain in Metal and use SceneKit only
  for the shell/overlays.
- **Whatever the renderer, preserve the invariants (§5) and the relevance
  contract:** overlays write relevance; emphasis MAX-combines, filters MASK, state
  clamps; LOD is camera-tied and dimming is pure opacity; ships never occlude.

Feature backlog if work continues here instead: search (feeds `LabelEngine` as a
priority source + frames the hit), trade-route overlay (another reference writer),
a symbol legend, bloom, and battery (redraw-on-input — `RelevanceField.step()`
already returns an "animating" flag; note the granulation spin + ship motion now
also want continuous frames).

---

## 8. Tunables reference

- **Sizing band, atmospheric dimming, exposure** — `StarFieldRenderer` tunables
  block. `minAngularSize`/`maxAngularSize` = the size-encodes-depth band;
  `atmoNear`/`atmoFar`/`atmoFloor` = atmospheric depth dimming (distinct from
  semantic relevance dimming); `exposure` = global tone-map (tune this if the
  core blows out); `lodStart`/`lodFull` = angular-size band over which a star
  cross-fades from glow sprite to luminous disc.
- **Focus falloff radius, floor, easing rate** — `RelevanceField`. NOTE the
  relevance model: **LOD is camera-tied only; dimming is pure OPACITY.** A
  de-emphasized star renders at its normal LOD (disc if close, glow if far) with
  full colour/detail, just made transparent (`alpha ∝ relevance` in
  `star_body_fragment`) — never a detail/LOD downgrade. Because a transparent disc
  must not hard-occlude a lit star behind it, bodies draw in TWO slices over the
  same geometry: opaque (relevance ≥ `bodyOpaqueThreshold`) writes depth; the dim
  slice is drawn after, transparent, depth-tested but not writing. Separately, the
  *amount* of focus dimming is gentle at dive scale because the falloff is a fixed
  40 ly — tightening/scaling it is a knob, but keep it OUT of opacity/LOD.
- **FTL mesh** — relay density (`relayFraction`) in `Galaxy.generate`; link range
  (`maxEdgeLength`, 7.5 ly) in `FTLMesh.build`; off-mesh relevance falloff
  (`meshFalloff`), link thickness (`meshLineHalfWidth`) and relay-ring radius
  (`meshNodeRadius`) in `StarFieldRenderer`; link/marker colors in `mesh_fragment`
  / `node_fragment` (`Shaders.metal`).
- **State overlay** — `StarFieldRenderer`: player/ship colors, marker radii,
  `shipLineHalfWidth`; ship pacing (`tripDuration`/`phase`) in the demo fleet
  setup; tail fade + dash density (`tailLength`/`dashPeriod` in `encodeStateOverlay`,
  read by `ship_line_fragment`).
- **Labels** — `maxContextLabels` in `StarFieldRenderer`; font size / raster scale
  in `LabelTextureCache`; anchor `gap` / `padding` in `LabelEngine.layout`; name
  syllables in `Galaxy.makeName`.
- **Data filters** — filter set / metrics in `DataFilter`; distributions
  (life/resource/scan weights) in `Galaxy.generate`; cycle order is
  `DataFilter.allCases`.
- **Status symbols** — the symbol vocabulary / gating (and the resource gauge's
  0…1 value) in `Star.statusSymbols`; the row's symbol size in `LabelTextureCache`
  (0.95× the name).
- **Refocus blend & framing easing** — `TurntableCamera`. `maxFocusRadius` = the
  near/far blend point (tilt-only vs zoom-toward, default 45 ly);
  `framingMinDuration`/`framingMaxDuration` = the 300–750 ms ease-in-out band;
  `eyeMoveReference`/`lookSwingReference` = how eye-move and orientation-swing map
  to duration. Elevation clamp (`minElevation`/`maxElevation`) is ±80°. Orbit
  sensitivity falloff: `orbitReferenceRadius` / `orbitMinSensitivity`. While
  focused, the dolly floor follows the star: `camera.focusFloor` is set to
  `worldRadius / maxAngularSize` (where the star fills its size cap) so you can't
  zoom past the point where it stops growing — no dead zone. The
  single-click re-aim, double-click `diveRadius` (12 ly) and `overviewRadius`
  (Home) distances live in `StarFieldRenderer`.
- **Galaxy shape, star count, spectral distribution, seed** — `Galaxy.generate`.
