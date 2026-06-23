//
//  GalaxyScene.swift
//  StarMapFeature
//
//  The imperative controller that owns the SceneKit scene graph, camera pose,
//  gestures, and animations. It never imports ComposableArchitecture — user
//  intents flow up through the `onIntent` closure; declarative state flows down
//  through the `apply(...)` methods, which are idempotent so the SwiftUI
//  representable can call them on every update without re-running work.
//

import AppKit
import SceneKit
import simd
import UI

/// Value-typed intents the scene emits upward (translated to store actions by
/// the SwiftUI Coordinator).
enum StarMapIntent: Equatable, Sendable {
    case selectedSystem(String?)   // nil = clicked empty space (deselect)
    case userInteracted
}

/// SCNView subclass so we can route the scroll wheel to zoom.
final class MapSCNView: SCNView {
    var onScroll: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

@MainActor
final class GalaxyScene: NSObject {
    let scnView: MapSCNView
    private let scene = SCNScene()
    private let rig = CameraRig()
    private let onIntent: (StarMapIntent) -> Void

    private let galaxyLayer = SCNNode()
    private let systemsRoot = SCNNode()
    private let relayLinksNode = SCNNode()
    private var ambientField: SCNNode?
    private var systemNodes: [String: SystemNode] = [:]

    // Mirrors of the last-applied declarative state, for idempotent applies.
    private var currentSelection: String?
    private var currentLayers: Set<InfoLayer> = []
    private var autoRotateEnabled = true
    private var currentResetToken = 0
    private var currentFocus: StarMapFocus = .galaxy
    private var inFlight = false

    private var lastPanLocation: CGPoint?
    private var idleTask: Task<Void, Never>?

    /// Below this camera distance, system labels are shown (LOD cull above it).
    private let labelDistanceThreshold: CGFloat = 400

    init(
        systems: [GalaxySystem],
        relays: [RelayLink],
        onIntent: @escaping (StarMapIntent) -> Void
    ) {
        self.scnView = MapSCNView()
        self.onIntent = onIntent
        super.init()
        configureView()
        buildScene(systems: systems, relays: relays)
        installGestures()
        updateLabelLOD()
        rearmIdle()
    }

    // MARK: - Setup

    private func configureView() {
        scnView.scene = scene
        scnView.pointOfView = rig.cameraNode
        scnView.allowsCameraControl = false   // we own the camera entirely
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.isPlaying = true               // keep the render loop live for actions
        scnView.backgroundColor = .black
        scene.background.contents = makeSpaceBackground()
        scnView.onScroll = { [weak self] delta in self?.handleScroll(delta) }
    }

    private func buildScene(systems: [GalaxySystem], relays: [RelayLink]) {
        scene.rootNode.addChildNode(rig.pivot)

        let field = AmbientField.makeNode()
        ambientField = field
        scene.rootNode.addChildNode(field)

        galaxyLayer.name = "galaxyLayer"
        scene.rootNode.addChildNode(galaxyLayer)
        relayLinksNode.name = "relayLinks"
        systemsRoot.name = "systems"
        galaxyLayer.addChildNode(relayLinksNode)
        galaxyLayer.addChildNode(systemsRoot)

        for system in systems {
            let node = SystemNode(system: system)
            systemNodes[system.id] = node
            systemsRoot.addChildNode(node)
        }
        buildRelayLinks(relays)
        relayLinksNode.isHidden = true   // shown when the relay layer is on
    }

    /// Deep-space radial gradient. These are the spec's one token-less colors
    /// ("Deep-space background #05070D → #0A0F1B"); everything else uses tokens.
    private func makeSpaceBackground() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(
            colors: [
                NSColor(hex: "#152238")!,
                NSColor(hex: "#0a0f1b")!,
                NSColor(hex: "#06080f")!,
            ],
            atLocations: [0, 0.55, 1],
            colorSpace: .sRGB
        )!
        let focus = NSPoint(x: size.width * 0.28, y: size.height * 0.86)
        gradient.draw(fromCenter: focus, radius: 0,
                      toCenter: focus, radius: size.width * 0.95, options: [])
        image.unlockFocus()
        return image
    }

    // MARK: - Relay links

    private func buildRelayLinks(_ relays: [RelayLink]) {
        for relay in relays {
            guard let a = systemNodes[relay.a]?.simdPosition,
                  let b = systemNodes[relay.b]?.simdPosition else { continue }
            let color = relay.owner == .mine ? MapPalette.accent : MapPalette.npc
            let link = SCNNode()
            link.name = "relay:\(relay.id)"

            // Sample a quadratic bezier bowed slightly off the disc; render as a
            // chain of short cylinders. Planned links skip alternate segments
            // (a dashed read) without needing a dashed material.
            let segments = 14
            let control = (a + b) / 2 + simd_float3(0, 12, 0)
            var prev = a
            for i in 1...segments {
                let t = Float(i) / Float(segments)
                let point = bezier(a, control, b, t)
                if !(relay.planned && i % 2 == 0) {
                    link.addChildNode(cylinder(from: prev, to: point, radius: 0.12, color: color))
                }
                prev = point
            }
            relayLinksNode.addChildNode(link)
        }
    }

    private func bezier(_ p0: simd_float3, _ c: simd_float3, _ p1: simd_float3, _ t: Float) -> simd_float3 {
        let u = 1 - t
        return u * u * p0 + 2 * u * t * c + t * t * p1
    }

    private func cylinder(from a: simd_float3, to b: simd_float3, radius: CGFloat, color: NSColor) -> SCNNode {
        let dir = b - a
        let height = simd_length(dir)
        let geometry = SCNCylinder(radius: radius, height: CGFloat(height))
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = (a + b) / 2
        if height > 1e-5 {
            node.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: simd_normalize(dir))
        }
        return node
    }

    // MARK: - Declarative state (idempotent)

    func apply(activeLayers: Set<InfoLayer>) {
        guard activeLayers != currentLayers else { return }
        currentLayers = activeLayers
        for node in systemNodes.values { node.apply(activeLayers: activeLayers) }
        relayLinksNode.isHidden = !activeLayers.contains(.relay)
    }

    func apply(selection: String?) {
        guard selection != currentSelection else { return }
        currentSelection = selection
        for (id, node) in systemNodes { node.setSelected(id == selection) }
        updateLabelLOD()
    }

    func apply(autoRotate: Bool) {
        guard autoRotate != autoRotateEnabled else { return }
        autoRotateEnabled = autoRotate
        if autoRotate {
            rearmIdle()
        } else {
            idleTask?.cancel()
            rig.stopAutoYaw()
        }
    }

    /// React to a recenter request (token-based, so it fires once per tap).
    func apply(resetToken: Int) {
        guard resetToken != currentResetToken else { return }
        currentResetToken = resetToken
        recenter()
    }

    func recenter() {
        rig.reset(animated: true)
        updateLabelLOD()
        rearmIdle()
    }

    // MARK: - Galaxy ↔ system transition

    func apply(focus: StarMapFocus) {
        guard focus != currentFocus, !inFlight else { return }
        switch focus {
        case let .system(id): flyTo(systemID: id)
        case .galaxy:         flyBack()
        }
    }

    /// Drill in: fly the pivot to the star, pull the camera close, fade the rest
    /// of the galaxy out, and assemble the orrery at ~0.55 of the move (§06).
    private func flyTo(systemID id: String) {
        guard let node = systemNodes[id] else { return }
        inFlight = true
        currentFocus = .system(id)
        idleTask?.cancel()
        rig.stopAutoYaw()

        let model = ChamakuyData.model(for: node.system)
        node.buildOrreryIfNeeded(model: model)

        let duration = 1.15
        scheduleOrreryReveal(node, after: 0.55 * duration)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rig.focus(on: node.simdWorldPosition, distance: CameraRig.systemDistance)
        node.enterSystemMode(sunRadiusScene: model.sunRadiusScene)
        fadeGalaxy(to: 0, excluding: id)
        SCNTransaction.commit()

        clearInFlight(after: duration)
    }

    /// Zoom out: retract the orrery, restore the galaxy, ease the camera back.
    private func flyBack() {
        guard case let .system(id) = currentFocus else { return }
        inFlight = true
        let node = systemNodes[id]
        node?.orrery?.retract()
        currentFocus = .galaxy

        let duration = 0.95
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rig.galaxyPose()
        node?.exitSystemMode(activeLayers: currentLayers)
        fadeGalaxy(to: 1, excluding: nil)
        SCNTransaction.commit()

        clearInFlight(after: duration) { [weak self] in
            self?.updateLabelLOD()
            self?.rearmIdle()
        }
    }

    /// Fade the galaxy backdrop (field + relays + every system but the focused
    /// one). The focused star stays opaque and continuous across the move.
    private func fadeGalaxy(to opacity: CGFloat, excluding id: String?) {
        ambientField?.opacity = opacity
        relayLinksNode.opacity = opacity
        for (sid, node) in systemNodes where sid != id {
            node.opacity = opacity
        }
    }

    private func scheduleOrreryReveal(_ node: SystemNode, after seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, case .system = self.currentFocus else { return }
            node.orrery?.reveal()
        }
    }

    private func clearInFlight(after seconds: Double, then: (@MainActor () -> Void)? = nil) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.inFlight = false
            then?()
        }
    }

    // MARK: - Gestures

    private func installGestures() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        scnView.addGestureRecognizer(pan)
        scnView.addGestureRecognizer(magnify)
        scnView.addGestureRecognizer(click)
    }

    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        let location = g.location(in: scnView)
        switch g.state {
        case .began:
            lastPanLocation = location
            beginInteraction()
        case .changed:
            guard let last = lastPanLocation else { return }
            let dx = location.x - last.x
            let dy = location.y - last.y
            lastPanLocation = location
            if NSEvent.modifierFlags.contains(.shift) {
                rig.pan(dx: dx, dy: dy)
            } else {
                rig.rotate(deltaYaw: dx * 0.005, deltaPitch: -dy * 0.005)
            }
            updateLabelLOD()
        case .ended, .cancelled, .failed:
            lastPanLocation = nil
            rearmIdle()
        default:
            break
        }
    }

    @objc private func handleMagnify(_ g: NSMagnificationGestureRecognizer) {
        switch g.state {
        case .began:
            beginInteraction()
        case .changed:
            rig.zoom(by: g.magnification * 220)
            g.magnification = 0    // make it incremental
            updateLabelLOD()
        case .ended, .cancelled, .failed:
            rearmIdle()
        default:
            break
        }
    }

    private func handleScroll(_ deltaY: CGFloat) {
        beginInteraction()
        rig.zoom(by: deltaY * 0.6)
        updateLabelLOD()
        rearmIdle()
    }

    @objc private func handleClick(_ g: NSClickGestureRecognizer) {
        beginInteraction()
        rearmIdle()
        // Galaxy selection only; in system focus the orrery isn't selectable yet.
        guard case .galaxy = currentFocus else { return }
        let point = g.location(in: scnView)
        onIntent(.selectedSystem(nearestSystem(to: point)))
    }

    /// Nearest system whose projected position is within ~22pt of `point`,
    /// in front of the camera. Projection beats geometry hit-testing for the
    /// tiny far stars.
    private func nearestSystem(to point: CGPoint) -> String? {
        var bestID: String?
        var bestDistance: CGFloat = 22
        for (id, node) in systemNodes {
            let projected = scnView.projectPoint(node.worldPosition)
            guard projected.z > 0, projected.z < 1 else { continue }
            let dx = CGFloat(projected.x) - point.x
            let dy = CGFloat(projected.y) - point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                bestID = id
            }
        }
        return bestID
    }

    // MARK: - Label LOD

    private func updateLabelLOD() {
        let show = rig.distance < labelDistanceThreshold
        for node in systemNodes.values {
            node.setLabelVisible(show || node.system.isHome || node.system.id == currentSelection)
        }
    }

    // MARK: - Idle auto-yaw

    private func beginInteraction() {
        idleTask?.cancel()
        rig.stopAutoYaw()
        onIntent(.userInteracted)
    }

    private func rearmIdle() {
        idleTask?.cancel()
        guard autoRotateEnabled else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self, !Task.isCancelled, self.autoRotateEnabled else { return }
            self.rig.startAutoYaw()
        }
    }
}
