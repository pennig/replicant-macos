//
//  CameraRig.swift
//  StarMapFeature
//
//  One gimbal pattern that serves the galaxy view (and, in Phase 2, the system
//  view and the transition). A pivot node sits at the look-at point; the camera
//  is its child, pulled back along −Z. Orbit = rotate the pivot; zoom = change
//  the camera's local z; pan = translate the pivot. HDR + bloom live on the
//  camera so star glow comes from material emission, not sprite stacks.
//

import SceneKit
import simd

@MainActor
final class CameraRig {
    let pivot = SCNNode()
    let cameraNode = SCNNode()

    // Tunables (scene units / radians).
    static let defaultDistance: CGFloat = 320
    static let systemDistance: CGFloat = 115   // framed for the orrery (±41 units)
    static let minDistance: CGFloat = 40
    static let maxDistance: CGFloat = 520
    static let pitchClamp: CGFloat = 1.5
    static let startPitch: CGFloat = -0.92
    static let startYaw: CGFloat = 0.5

    init() {
        let camera = SCNCamera()
        // Bloom (and the HDR pipeline that fed it) is off: it washed the systems
        // out and brightened the whole frame as you zoomed out, because HDR
        // exposure adapts to how much emissive content is in view. Plain LDR
        // rendering keeps brightness constant at every zoom level.
        camera.wantsHDR = false
        camera.bloomIntensity = 0
        camera.fieldOfView = 38
        // Pin the FOV to the vertical axis so the optical-shift reconstruction
        // below can derive `f` (= cot(fov/2)) independent of the view aspect.
        camera.projectionDirection = .vertical
        camera.zNear = 0.5
        camera.zFar = 6000
        cameraNode.camera = camera
        cameraNode.name = "camera"
        cameraNode.position = SCNVector3(0, 0, Self.defaultDistance)

        pivot.name = "cameraPivot"
        pivot.addChildNode(cameraNode)
        pivot.eulerAngles = SCNVector3(Self.startPitch, Self.startYaw, 0)
    }

    // MARK: - Pose

    var distance: CGFloat {
        get { cameraNode.position.z }
        set { cameraNode.position.z = newValue.clamped(Self.minDistance, Self.maxDistance) }
    }

    /// Orbit: yaw is unbounded; pitch is clamped to keep the disc readable.
    func rotate(deltaYaw: CGFloat, deltaPitch: CGFloat) {
        var e = pivot.eulerAngles
        e.y += deltaYaw
        e.x = (e.x + deltaPitch).clamped(-Self.pitchClamp, Self.pitchClamp)
        pivot.eulerAngles = e
    }

    /// Zoom by a wheel/pinch delta (positive = zoom in).
    func zoom(by delta: CGFloat) {
        distance = cameraNode.position.z - delta
    }

    /// Pan the look-at point in the pivot's own screen plane.
    func pan(dx: CGFloat, dy: CGFloat) {
        let right = pivot.simdWorldRight
        let up = pivot.simdWorldUp
        let scale = Float(distance) * 0.0016
        pivot.simdWorldPosition += (right * Float(-dx) + up * Float(dy)) * scale
    }

    /// Slow idle yaw — a repeating action on the pivot.
    func startAutoYaw() {
        guard pivot.action(forKey: "autoYaw") == nil else { return }
        let spin = SCNAction.repeatForever(
            .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 90)
        )
        pivot.runAction(spin, forKey: "autoYaw")
    }

    func stopAutoYaw() {
        pivot.removeAction(forKey: "autoYaw")
    }

    /// Aim the pivot at a world point and pull the camera to a distance. Call
    /// inside an SCNTransaction to animate the move (used by the drill-in fly).
    func focus(on worldPosition: simd_float3, distance: CGFloat) {
        pivot.simdWorldPosition = worldPosition
        cameraNode.position.z = distance
    }

    /// Set the default galaxy pose (no implicit animation).
    func galaxyPose() {
        pivot.simdWorldPosition = .zero
        pivot.eulerAngles = SCNVector3(Self.startPitch, Self.startYaw, 0)
        cameraNode.position.z = Self.defaultDistance
    }

    // MARK: - Optical shift (sidebar-aware centering)

    // Captured once from SceneKit's own symmetric projection so the off-center
    // reconstruction inherits SceneKit's depth/clip convention exactly.
    private var baseVerticalF: Float?
    private var baseC2z: Float = 0
    private var baseC2w: Float = -1
    private var baseC3z: Float = 0
    private var opticalShiftNDC: Float = 0

    /// Horizontal optical shift, in normalized device coords. A positive value
    /// nudges the rendered content to the right — used to recenter the scene in
    /// the area the translucent sidebar leaves clear. This shifts the *image*
    /// only; the look-at point and orbit center are untouched, so the galaxy
    /// still spins about its true center.
    func setOpticalShift(_ ndc: Float) {
        opticalShiftNDC = ndc
    }

    /// Rebuild the (possibly off-center) projection for the current drawable
    /// aspect. Cheap; call from the view's layout pass.
    func updateProjection(aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0, let camera = cameraNode.camera else { return }
        if baseVerticalF == nil {
            // Read SceneKit's symmetric matrix before we ever override it.
            let base = simd_float4x4(camera.projectionTransform)
            baseVerticalF = base.columns.1.y          // cot(fovY/2), aspect-independent
            baseC2z = base.columns.2.z
            baseC2w = base.columns.2.w
            baseC3z = base.columns.3.z
        }
        guard let f = baseVerticalF else { return }
        var m = simd_float4x4(0)
        m.columns.0 = SIMD4(f / Float(aspect), 0, 0, 0)
        m.columns.1 = SIMD4(0, f, 0, 0)
        // columns.2.x is the off-center term: ndc.x of the look-at point becomes
        // -columns.2.x, so negate the desired shift to push content right.
        m.columns.2 = SIMD4(-opticalShiftNDC, 0, baseC2z, baseC2w)
        m.columns.3 = SIMD4(0, 0, baseC3z, 0)
        camera.projectionTransform = SCNMatrix4(m)
    }

    /// Ease back to the default galaxy pose.
    func reset(animated: Bool) {
        stopAutoYaw()
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.6
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            galaxyPose()
            SCNTransaction.commit()
        } else {
            galaxyPose()
        }
    }
}

extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, low), high)
    }
}
