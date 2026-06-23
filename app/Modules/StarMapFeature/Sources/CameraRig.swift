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
        camera.wantsHDR = true
        camera.bloomIntensity = 0.35      // spec §4 — dialed down vs the canvas fake
        camera.bloomThreshold = 0.8
        camera.bloomBlurRadius = 8
        camera.fieldOfView = 38
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
