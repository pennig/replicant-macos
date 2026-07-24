import Testing
import simd
@testable import NewStarMapFeature

// LabelSelection is the off-main half of the label pass — pure math over star +
// camera snapshots — so it gets direct unit coverage: culling, budget ranking,
// the always-included selection, and the system-focus recession exemption.

@MainActor
@Suite struct LabelSelectionTests {

    /// A camera at +z looking at the origin, viewport 800×600.
    private func camera(eyeZ: Float = 100) -> LabelSelection.Camera {
        let eye = SIMD3<Float>(0, 0, eyeZ)
        return LabelSelection.Camera(
            view: .lookAt(eye: eye, center: .zero, up: SIMD3<Float>(0, 1, 0)),
            projection: .perspective(fovyRadians: 60 * .pi / 180, aspect: 800 / 600,
                                     near: 0.05, far: 4000),
            width: 800, height: 600, eye: eye)
    }

    private func field(positions: [SIMD3<Float>],
                       focused: Int? = nil, reveal: Float = 0) -> LabelSelection.Field {
        LabelSelection.Field(
            positions: positions,
            worldRadii: [Float](repeating: 0.1, count: positions.count),
            focusedStar: focused, orreryReveal: reveal,
            orreryCenter: .zero, systemPush: 2.0,
            minAngularSize: 0.0015, maxAngularSize: 0.05, ringFloor: 8)
    }

    @Test func cullsBehindCameraAndOffscreen() {
        let f = field(positions: [
            SIMD3(0, 0, 0),        // dead centre — visible
            SIMD3(0, 0, 200),      // behind the camera (eye at z=100 looking at origin)
            SIMD3(5000, 0, 0),     // far outside the frustum
        ])
        let chosen = LabelSelection.choose(field: f, camera: camera(), budget: 10, selected: nil)
        #expect(chosen.map(\.index) == [0])
    }

    @Test func budgetKeepsTheNearestStars() {
        // Three visible stars at increasing depth; a budget of 2 keeps the nearest two.
        let f = field(positions: [
            SIMD3(0, 0, -50),      // farthest
            SIMD3(2, 0, 20),       // nearest
            SIMD3(-2, 0, 0),       // middle
        ])
        let chosen = LabelSelection.choose(field: f, camera: camera(), budget: 2, selected: nil)
        #expect(chosen.map(\.index) == [1, 2])
        #expect(chosen[0].distance < chosen[1].distance)
    }

    @Test func selectionIsAlwaysIncludedAndOutranks() {
        let f = field(positions: [
            SIMD3(0, 0, 20),
            SIMD3(1, 0, 10),
            SIMD3(0, 1, -60),      // farthest — would miss a budget of 2
        ])
        let chosen = LabelSelection.choose(field: f, camera: camera(), budget: 2, selected: 2)
        #expect(chosen.contains { $0.index == 2 })
        // The appended selection carries distance 0 so downstream priority ranks it first.
        #expect(chosen.first { $0.index == 2 }?.distance == 0)
    }

    @Test func zeroBudgetStillLabelsTheSelection() {
        let f = field(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)])
        let chosen = LabelSelection.choose(field: f, camera: camera(), budget: 0, selected: 1)
        #expect(chosen.map(\.index) == [1])
    }

    @Test func recessionPushesUnfocusedStarsOnly() {
        // With the drill fully revealed, an unfocused star is pushed radially away
        // from the orrery centre (so its projection moves outward); the focused
        // star must not move at all.
        let positions = [SIMD3<Float>(3, 0, 0), SIMD3<Float>(-3, 0, 0)]
        let atRest = field(positions: positions)
        let drilled = field(positions: positions, focused: 0, reveal: 1)

        let restFocused = LabelSelection.project(0, field: atRest, camera: camera())
        let drilledFocused = LabelSelection.project(0, field: drilled, camera: camera())
        #expect(restFocused?.screen == drilledFocused?.screen)

        let restOther = LabelSelection.project(1, field: atRest, camera: camera())
        let drilledOther = LabelSelection.project(1, field: drilled, camera: camera())
        // Pushed 3× farther from centre (1 + push·reveal = 3) → strictly farther left.
        #expect(drilledOther != nil)
        #expect(drilledOther!.screen.x < restOther!.screen.x)
        #expect(drilledOther!.distance > restOther!.distance)
    }
}
