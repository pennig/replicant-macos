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

    /// The scaffold shaders compute `orreryCentre + local * orreryReveal` from
    /// buffers baked around a fixed origin. Pushing every such point is identical
    /// to pushing the CENTRE and multiplying the REVEAL by the same factor — which
    /// is why the push needs no shader change and no buffer rebuild, and why the
    /// baked build-centre must NOT itself be pushed.
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

    /// `OrreryLayout` places every anchor at `centre + direction · sceneRadius · scale
    /// · reveal`. Pushing such a layer means pushing its CENTRE and multiplying exactly
    /// ONE of `scale` / `reveal` — the renderer uses `reveal`, since the scaffold
    /// shaders have no scale and body radii come off `scale`. Doing both squares the
    /// factor, which is what made bodies fly out past their own rings.
    @Test func layerFactorAppliesExactlyOnce() {
        let push = OrreryPush(pivot: pivot, progress: 1, strength: 5)   // factor 6
        let center = SIMD3<Float>(-4, 2, 1)
        let direction = SIMD3<Float>(0, 0, 1)
        let sceneRadius: Float = 3, scale: Float = 2, reveal: Float = 0.5

        let truePosition = center + direction * (sceneRadius * scale * reveal)
        let pushedOnce = push(center) + direction * (sceneRadius * scale * (reveal * push.factor))
        #expect(simd_distance(pushedOnce, push(truePosition)) < 1e-3)

        // …and the doubled form is NOT the push, by a wide margin.
        let pushedTwice = push(center)
            + direction * (sceneRadius * (scale * push.factor) * (reveal * push.factor))
        #expect(simd_distance(pushedTwice, push(truePosition)) > 1)
    }

    /// The pivot being an exact fixed point means distance from it only ever scales, so
    /// no body can cross the drilled planet on its way out however far it is flung.
    @Test func distanceFromPivotOnlyScales() {
        let push = OrreryPush(pivot: pivot, progress: 1, strength: 5)
        for p in [SIMD3<Float>(9, 4, -2), SIMD3<Float>(-30, 0, 5), pivot + SIMD3<Float>(0.01, 0, 0)] {
            let before = simd_distance(p, pivot)
            let after = simd_distance(push(p), pivot)
            #expect(abs(after - before * push.factor) < 1e-3)
        }
    }

    @Test func identityConstantLeavesEveryPointAlone() {
        let p = SIMD3<Float>(1, 2, 3)
        #expect(OrreryPush.identity(p) == p)
        #expect(OrreryPush.identity.isIdentity)
    }
}
