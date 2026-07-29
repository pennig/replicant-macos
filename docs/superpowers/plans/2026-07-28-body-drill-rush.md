# System→body drill rush Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the system↔body drill/zoom fling the rest of the system away from the drilled planet — rings spreading, sun and siblings receding to points — instead of letting it slide sideways and fade.

**Architecture:** One uniform scale `k = 1 + bodyPush · bodyProgress` about the drilled planet's live world position, applied to the *system*-level orrery layer only. Because an `OrreryLayout` is an affine map of scene coordinates and the scaffold shaders already compute `orreryCenter + local · orreryReveal`, the whole push composes into `(center', scale', reveal')` — so the scaffold and every layout consumer need no new shader work. Only the focused star (which *is* the sun — there is no sun body) needs a genuine shader push, via two new `Uniforms` fields.

**Tech Stack:** Swift 6 / SwiftPM (`app/Modules`), raw Metal (`.metal` resources + a shared C struct header in `CShaderTypes`), Swift Testing.

## Global Constraints

- Design source of truth: `Modules/UI/DESIGN_SPEC.md`; never hard-code colors, spacing, or font sizes. (No UI tokens are touched by this plan.)
- `os.Logger` only, never `print`.
- Read `swift test` results from the Swift Testing JSON event stream via the repo's `swift-test-event-stream` skill — never by grepping console text.
- LSP root is `app/Modules`. A fresh worktree needs `swift build --build-tests` then `./scripts/link-index-store.sh` before reference queries mean anything.
- Full-drill strength is `bodyPush = 5`, i.e. `k` tops out at **6**. This value was chosen by the user; do not retune it without asking.
- The `Uniforms` struct in `CShaderTypes/include/ShaderTypes.h` is shared CPU↔GPU. Field order there is the layout contract — append new scalars beside their siblings and keep Swift/Metal in sync.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/Modules/NewStarMapFeature/Sources/OrreryPush.swift` | **New.** The pure transform: a uniform scale about a pivot, plus the `(center, scale, reveal)` composition the render path relies on. No Metal, no renderer state — unit-testable in isolation. |
| `app/Modules/NewStarMapFeature/Tests/OrreryPushTests.swift` | **New.** Tests for the transform's algebraic properties. |
| `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` | Owns the tunable, derives the live push each frame, and applies it to the system layer (scaffold uniforms, placed bodies, pips, `frameOrreryLayout`). |
| `app/Modules/NewStarMapFeature/CShaderTypes/include/ShaderTypes.h` | Two new `Uniforms` fields (`bodyPush`, `bodyPivot`) so the star field can push the sun. |
| `app/Modules/NewStarMapFeature/Sources/StarField.metal` | Pushes the focused star (the sun) away from the drilled planet. |

---

### Task 1: The pure push transform

**Files:**
- Create: `app/Modules/NewStarMapFeature/Sources/OrreryPush.swift`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryPushTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct OrreryPush` with `init(pivot: SIMD3<Float>, progress: Float, strength: Float)`, `static let identity: OrreryPush`, `var factor: Float`, `var pivot: SIMD3<Float>`, `var isIdentity: Bool`, and `func callAsFunction(_ p: SIMD3<Float>) -> SIMD3<Float>`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import simd
@testable import NewStarMapFeature

// The system layer's recession from a drilled planet: a uniform scale about that
// planet. The render path leans on two algebraic facts — the pivot is an exact
// fixed point, and the scale composes into an OrreryLayout's (centre, scale) and
// the scaffold shaders' (orreryCentre, orreryReveal) — so both are pinned here.
struct OrreryPushTests {
    private let pivot = SIMD3<Float>(3, -1, 7)

    @Test func identityAtZeroProgress() {
        let push = OrreryPush(pivot: pivot, progress: 0, strength: 5)
        #expect(push.factor == 1)
        #expect(push.isIdentity)
        let p = SIMD3<Float>(10, 20, 30)
        #expect(push(p) == p)
    }

    @Test func pivotIsAFixedPointAtAnyProgress() {
        for progress in [Float(0), 0.25, 0.5, 1] {
            let push = OrreryPush(pivot: pivot, progress: progress, strength: 5)
            #expect(simd_distance(push(pivot), pivot) < 1e-5)
        }
    }

    @Test func fullProgressScalesByOnePlusStrength() {
        let push = OrreryPush(pivot: pivot, progress: 1, strength: 5)
        #expect(push.factor == 6)
        let p = pivot + SIMD3<Float>(2, 0, 0)
        #expect(simd_distance(push(p), pivot + SIMD3<Float>(12, 0, 0)) < 1e-4)
    }

    @Test func factorIsLinearInProgressSoTheUnwindIsSymmetric() {
        let half = OrreryPush(pivot: pivot, progress: 0.5, strength: 5)
        #expect(abs(half.factor - 3.5) < 1e-6)
    }

    // The scaffold shaders compute `orreryCentre + local * orreryReveal` from
    // buffers baked around a fixed origin. Pushing every such point is identical
    // to pushing the CENTRE and multiplying the REVEAL by the same factor — which
    // is why the push needs no shader change and no buffer rebuild.
    @Test func composesIntoCentreAndReveal() {
        let push = OrreryPush(pivot: pivot, progress: 0.7, strength: 5)
        let center = SIMD3<Float>(-4, 2, 1)
        let reveal: Float = 0.8
        for local in [SIMD3<Float>(5, 0, 0), SIMD3<Float>(-2, 3, 9), .zero] {
            let direct = push(center + local * reveal)
            let composed = push(center) + local * (reveal * push.factor)
            #expect(simd_distance(direct, composed) < 1e-3)
        }
    }

    @Test func identityConstantLeavesEveryPointAlone() {
        let p = SIMD3<Float>(1, 2, 3)
        #expect(OrreryPush.identity(p) == p)
        #expect(OrreryPush.identity.isIdentity)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run from `app/Modules`:
```bash
swift test --filter OrreryPushTests --event-stream-output-path "$CLAUDE_JOB_DIR/tmp/push-events.jsonl"
```
Expected: FAIL — `cannot find 'OrreryPush' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrreryPush.swift`:

```swift
import simd

/// The system layer's recession from a drilled planet: a uniform scale about that
/// planet's live world position, ramped by the system↔body cross-fade.
///
/// Drilling from a system into one of its planets is not a real dive — the camera
/// ends up about as far from the planet as it was from the star, and the sense of
/// zoom comes from the central body being grown. So the rest of the system, left at
/// its true world positions, can only slide sideways and fade. Scaling it out from
/// the drilled planet is what turns that into a fly-in: orbit radii AND their
/// spacing grow together, and the sun and siblings — which sit closer to the planet
/// than the camera does — are flung past the camera and shrink to points.
///
/// The drilled planet is already the one body a system layer excludes (it is drawn
/// once as the continuous central body), so it is the exact fixed point here, with
/// nothing to reconcile between the two layers.
struct OrreryPush {
    /// The drilled planet's live world position — the one point that does not move.
    var pivot: SIMD3<Float>
    /// Distance multiplier. 1 = no push.
    var factor: Float

    /// No push at all — the system level, and every layer that IS the drilled body.
    static let identity = OrreryPush(pivot: .zero, factor: 1)

    private init(pivot: SIMD3<Float>, factor: Float) {
        self.pivot = pivot
        self.factor = factor
    }

    /// `strength` is the extra distance factor at full drill (0 = none), ramped by
    /// the eased cross-fade `progress` — mirroring how the galaxy field's
    /// `systemPush` is ramped by the eased `orreryReveal`, so the rush peaks with
    /// the fade instead of fighting it.
    init(pivot: SIMD3<Float>, progress: Float, strength: Float) {
        self.init(pivot: pivot, factor: 1 + strength * progress)
    }

    var isIdentity: Bool { factor == 1 }

    func callAsFunction(_ p: SIMD3<Float>) -> SIMD3<Float> {
        pivot + (p - pivot) * factor
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run from `app/Modules`:
```bash
swift test --filter OrreryPushTests --event-stream-output-path "$CLAUDE_JOB_DIR/tmp/push-events.jsonl"
```
Read the result from the event stream (per the `swift-test-event-stream` skill), not the console text. Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/OrreryPush.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryPushTests.swift
git commit -m "Add the orrery push transform"
```

---

### Task 2: Push the system orrery layer

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift`

**Interfaces:**
- Consumes: `OrreryPush(pivot:progress:strength:)`, `OrreryPush.identity`, `push.factor`, `push(_:)` from Task 1.
- Produces: `private var bodyPush: Float` (tunable, 5), `private var livePush: OrreryPush` (the frame's push, identity unless a body cross-fade is live), and an extra `push: OrreryPush` parameter on `encodeOrreryLayer`.

- [ ] **Step 1: Add the tunable**

In the tunables block beside `systemPush` / `fieldShrink` / `fieldFloor` (around line 514), add:

```swift
    // System→body recession: how far the SYSTEM layer is scaled away from the
    // drilled planet across the cross-fade. The galaxy drill has `systemPush` for
    // exactly this job one level up; without a counterpart here the siblings and
    // the sun stay at comparable depth to the arriving moon system and can only
    // slide and fade. 5 → they end up 6× further out. See `OrreryPush`.
    private var bodyPush: Float = 5
```

- [ ] **Step 2: Derive the frame's push**

Add, near `layerOpacity(isBody:)` (around line 276):

```swift
    /// The drilled planet's live world position while a body cross-fade is in play —
    /// the centre of the ACTIVE layer at body level, or of the DEPARTING one during a
    /// zoom-out. Both are already tracked onto the planet every frame
    /// (`trackBodyCentre` / `trackDepartingBodyCentre`), so either is exact.
    private var bodyPivot: SIMD3<Float>? {
        if orreryIsBody { return orreryCenter }
        if let d = departing, d.isBody { return d.center }
        return nil
    }

    /// This frame's recession of the SYSTEM layer away from the drilled planet.
    /// Identity whenever there is no body in play, so galaxy and system levels are
    /// untouched. Never applied to a body-level layer — that layer IS the pivot.
    private var livePush: OrreryPush {
        guard let pivot = bodyPivot, bodyProgress > 0 else { return .identity }
        return OrreryPush(pivot: pivot, progress: bodyProgress, strength: bodyPush)
    }
```

- [ ] **Step 3: Give `encodeOrreryLayer` a push parameter**

Change the signature (around line 1773) to take `push: OrreryPush` after `excludeID`, and document it:

```swift
    /// `push` scales a SYSTEM layer away from the drilled planet across the body
    /// cross-fade (identity for a body layer, which is the pivot). It composes into
    /// the layer's centre + reveal + scale, so the scaffold shaders and the layout
    /// need no push-awareness of their own — see `OrreryPush`.
```

Inside, replace the centre/reveal writes so the push is composed in, and derive the pushed scale + sun once:

```swift
        var u = baseUniforms
        let center = push(center)             // pushed layer centre …
        let emergeReveal = emergeReveal * push.factor   // … paired with a scaled reveal
        let scale = scale * push.factor
        let sun = push(sun)                   // light moves with the layer → lit faces hold
        u.orreryCenter = SIMD4(center, 0)     // the scaffold grows out of THIS layer's centre
        u.orreryBuildCenter = SIMD4(buildCenter, 0)   // …rebased from where it was baked
        u.orreryReveal = emergeReveal         // orbits/scaffold emerge from the centre by this
        u.orreryAlpha = alphaReveal           // fade this layer independently of the grow-out
        u.bodyPush = 0                        // the sun's push is a star-field concern, not a layer's
```

(Shadowing the parameters keeps every downstream use — `placedOrreryBodies`, `orreryPips`, the belt/HZ/line draws — on the pushed values with no further edits. `buildCenter` is deliberately *not* pushed: it is the baked origin the shaders subtract, and the composition identity in `OrreryPushTests.composesIntoCentreAndReveal` depends on it staying put.)

- [ ] **Step 4: Undo the push on body radii**

The scaled `scale` above would also grow every body's radius by `k`, cancelling the recession. Bodies should keep their true world radius and shrink purely by perspective. Immediately after the `placedOrreryBodies(...)` call (around line 1836), add:

```swift
        // `scale` carries the push so ORBIT geometry spreads; a body's own radius must
        // not, or a receding planet would grow by exactly the factor it recedes and
        // appear not to move at all.
        let placed = placedOrreryBodies(...).map { body -> PlacedBody in
            guard !push.isIdentity else { return body }
            var b = body
            b.radius /= push.factor
            return b
        }
```

- [ ] **Step 5: Pass the push at both call sites**

In `draw` (around line 968), the departing layer gets the push only when it is a *system* layer, and the active layer likewise:

```swift
                let push = livePush
                if let dep = departing {
                    encodeOrreryLayer(
                        …,
                        writesDepth: false, excludeID: dep.isBody ? nil : bodyPlanetID,
                        push: dep.isBody ? .identity : push,
                        …)
                }
                if let model = orreryModel {
                    encodeOrreryLayer(
                        …,
                        writesDepth: true, excludeID: orreryIsBody ? nil : bodyPlanetID,
                        push: orreryIsBody ? .identity : push,
                        …)
                }
```

- [ ] **Step 6: Push the shared frame layout**

`frameOrreryLayout` (around line 835) feeds the pips, ship heads, selection ring, transit risers, and the SwiftUI overlay projections. On a zoom-out the arriving *system* layer is the active one, so without the same composition those would detach from the pushed rings for the whole pull-back:

```swift
        frameOrreryLayout = {
            guard systemFocused, orreryReveal > 0.001, let model = orreryModel else { return nil }
            let reveal = orreryIsBody ? bodyProgress : orreryReveal
            // A system layer rides the same recession its rings do, so everything
            // anchored to it (ships, pips, selection, the SwiftUI overlays) stays
            // registered through the cross-fade. A body layer is the pivot.
            let push = orreryIsBody ? OrreryPush.identity : livePush
            return orreryLayout(model: model, center: push(orreryCenter),
                                scale: orreryScale * push.factor,
                                reveal: reveal * push.factor, time: orbitClock)
        }()
```

- [ ] **Step 7: Build**

Run from `app/Modules`:
```bash
swift build --build-tests 2>&1 | tail -20
```
Expected: build succeeds with no new warnings. (`Uniforms.bodyPush` does not exist yet — if Step 3's `u.bodyPush = 0` fails to compile, do Task 3's Step 1 first, then return here.)

- [ ] **Step 8: Run the module's tests**

```bash
swift test --filter NewStarMapFeatureTests --event-stream-output-path "$CLAUDE_JOB_DIR/tmp/starmap-events.jsonl"
```
Expected: no regressions. The push is identity everywhere `bodyProgress == 0`, so no existing orrery test should change.

- [ ] **Step 9: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift
git commit -m "Fling the system layer away from the drilled planet"
```

---

### Task 3: Push the sun

**Files:**
- Modify: `app/Modules/NewStarMapFeature/CShaderTypes/include/ShaderTypes.h`
- Modify: `app/Modules/NewStarMapFeature/Sources/StarField.metal`
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift`

**Interfaces:**
- Consumes: `livePush` from Task 2.
- Produces: `Uniforms.bodyPush: Float` and `Uniforms.bodyPivot: simd_float4`.

- [ ] **Step 1: Add the uniform fields**

In `ShaderTypes.h`, directly after `float fieldShrink;`:

```c
    // System→body recession of the SUN. There is no sun BODY — the focused star
    // field star is the sun — so the star field has to fly it away from the drilled
    // planet itself, matching what the system orrery layer does around it.
    // `bodyPush` is the extra radial distance factor (0 = none), already ramped by
    // the cross-fade on the CPU; `bodyPivot` is the drilled planet's live position.
    // Because the push is RADIAL from that planet, the star stays exactly on the
    // planet→sun lighting ray, so the lit faces keep pointing at the visible sun.
    float bodyPush;
```

and directly after `simd_float4 fieldCenter;`:

```c
    simd_float4 bodyPivot;
```

- [ ] **Step 2: Push the focused star**

In `StarField.metal`, extend the recession block in `star_vertex` (around line 37) so the focused star gets its own push:

```metal
    if (!isFocused && u.orreryReveal > 0.0) {
        float3 toStar = worldPos - u.fieldCenter.xyz;
        worldPos = u.fieldCenter.xyz + toStar * (1.0 + u.systemPush * u.orreryReveal);
    } else if (isFocused && u.bodyPush > 0.0) {
        // Drilling PAST the star into one of its planets: the sun flies away from
        // that planet exactly as the rest of the system does, so it recedes to a
        // point instead of hanging at the same depth as the arriving moon system.
        // The background sky is deliberately left alone — those stars are ly away,
        // already pushed and dimmed to the backdrop floor, and pivoting them on a
        // planet would swing the whole sky.
        float3 toPivot = worldPos - u.bodyPivot.xyz;
        worldPos = u.bodyPivot.xyz + toPivot * (1.0 + u.bodyPush);
    }
```

- [ ] **Step 3: Feed them from the renderer**

In `makeUniforms()` (around line 3037), add — the push is already ramped, so the shader takes `factor - 1`:

```swift
            systemPush: systemPush,
            fieldShrink: fieldShrink,
            bodyPush: livePush.factor - 1,
```

and beside `fieldCenter`:

```swift
            bodyPivot: SIMD4(bodyPivot ?? .zero, 0)
```

- [ ] **Step 4: Build**

Run from `app/Modules`:
```bash
swift build --build-tests 2>&1 | tail -20
```
Expected: succeeds. Metal is compiled as a processed resource, so a shader syntax error surfaces here.

- [ ] **Step 5: Compile-check the app target**

```bash
cd app && xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/CShaderTypes/include/ShaderTypes.h \
        app/Modules/NewStarMapFeature/Sources/StarField.metal \
        app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift
git commit -m "Fly the sun away on the drill into a planet"
```

---

### Task 4: Visual verification

**Files:** none (verification only; any fix lands as its own commit).

- [ ] **Step 1: Run the app and drill in**

Use the repo's `run` skill to launch. Drill Stars → a system → a planet, and screenshot mid-transition and settled.

Confirm:
- Orbit rings grow **and** spread apart, centered on the selected planet.
- The sun and sibling planets fly outward and become points, rather than sliding and fading at the same depth.
- The drilled planet itself does not shift, judder, or change size discontinuously — it is the pivot, so any motion there is a registration bug.

- [ ] **Step 2: Zoom back out and check the mirror**

Confirm the system converges back in as it fades in, and lands with nothing skipping at the hand-off (the departing body layer and the arriving system's copy of that planet must stay registered — see `trackDepartingBodyCentre`).

- [ ] **Step 3: Check the habitable-zone band**

The HZ band is a large additive filled annulus and the camera sits ~25° above the orbital plane, so an expanding band sweeps beneath it. If it washes the lower frame, front-load the scaffold's fade on a pushed layer (multiply the HZ/belt draws' `orreryAlpha` by `saturate(2 · (1 − bodyProgress))` on the way in) rather than weakening the push — the push strength is the user's choice.

- [ ] **Step 4: Update the module memory note**

Append the effect to `app/.claude/memory/orrery-physical-fidelity.md` or add a new note plus its `MEMORY.md` index line, recording: why the deeper drill needed a push at all (the camera does not actually dive), and the composition identity that lets the scaffold shaders stay untouched.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Record the drill-rush effect in the module memory"
```

---

## Self-Review

**Spec coverage.** Rings spreading + sun and siblings flying out → Tasks 2 and 3. Fade untouched → no task modifies `alphaReveal` / `layerOpacity` / `overlayDim`. Zoom-out mirror → free from `bodyProgress` unwinding, verified in Task 4 Step 2. Background sky untouched → the `else if (isFocused …)` branch in Task 3 Step 2 leaves the non-focused path exactly as it was. Picking untouched → `pickLocation` builds its own layout from the unpushed `orreryCenter` / `orreryScale`; no task edits it. HZ-band risk → Task 4 Step 3. `bodyPush = 5` → Task 2 Step 1.

**Placeholder scan.** No TBDs. The `…` in Task 2 Step 5 elides existing unchanged arguments at a call site the implementer is editing in place, not undefined behaviour.

**Type consistency.** `OrreryPush` is spelled identically across Tasks 1–3; `factor`, `pivot`, `isIdentity`, `identity`, and `callAsFunction` all match their definitions. `Uniforms.bodyPush` is written in Task 2 Step 3 and defined in Task 3 Step 1 — the build ordering note in Task 2 Step 7 covers that.
