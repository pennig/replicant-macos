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
    /// Fired whenever the view is (re)laid out or attached to a window, so the
    /// scene can refresh the sidebar-aware optical shift.
    var onLayout: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
    }
}

extension NSView {
    /// Nearest ancestor split view, if any (NavigationSplitView is NSSplitView-backed).
    var enclosingSplitView: NSSplitView? {
        var view = superview
        while let current = view {
            if let split = current as? NSSplitView { return split }
            view = current.superview
        }
        return nil
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
    private var starShell: SCNNode?
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
        // The sidebar can resize/collapse without changing our (full-bleed) frame,
        // so listen for split-view layout changes too — not just our own.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        scnView.onLayout = { [weak self] in self?.relayout() }
    }

    // MARK: - Sidebar-aware centering

    @objc private func splitViewDidResize() { relayout() }

    /// Recompute the camera's optical shift and projection so the scene is
    /// centered in the region the (translucent, full-height) sidebar leaves clear.
    private func relayout() {
        let bounds = scnView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let obscured = leadingObscuredWidth()
        // ndc shift = fraction of full width hidden on the leading edge; this
        // centers content in the visible span [obscured, width].
        rig.setOpticalShift(Float(obscured / bounds.width))
        rig.updateProjection(aspect: bounds.width / bounds.height)
    }

    /// How much of our leading edge is covered by the split view's sidebar.
    /// Zero when the scene sits beside the sidebar rather than under it, so the
    /// correction self-disables when there's nothing to correct.
    private func leadingObscuredWidth() -> CGFloat {
        guard let split = scnView.enclosingSplitView,
              let sidebar = split.arrangedSubviews.first,
              sidebar !== scnView, sidebar.window != nil,
              !sidebar.isHidden, sidebar.frame.width > 0 else { return 0 }
        // Trailing edge of the sidebar expressed in our coordinates: ≤ 0 when the
        // sidebar is entirely to our left (no overlap), positive when it overlaps.
        let trailing = sidebar.convert(NSPoint(x: sidebar.bounds.maxX, y: sidebar.bounds.midY), to: scnView)
        return max(0, min(trailing.x, scnView.bounds.width))
    }

    private func buildScene(systems: [GalaxySystem], relays: [RelayLink]) {
        scene.rootNode.addChildNode(rig.pivot)

        let shell = AmbientField.makeStarShell()
        starShell = shell
        // Skybox behavior: keep the shell centered on the camera (no parallax —
        // the stars read as infinitely far) while preserving its own fixed
        // orientation, so orbiting the camera sweeps past different stars.
        let follow = SCNReplicatorConstraint(target: rig.cameraNode)
        follow.replicatesOrientation = false
        follow.replicatesScale = false
        follow.replicatesPosition = true
        shell.constraints = [follow]
        scene.rootNode.addChildNode(shell)

        let field = AmbientField.makeNode(tints: ambientTints())
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

    /// Deep-space backdrop. A dark, full-bleed vignette over the spec's
    /// token-less deep-space tones ("#05070D → #0A0F1B"), lifted with a few
    /// faint token-tinted nebula washes — never the daytime-blue wash it used to
    /// be. Stars live in the 3D star shell (`AmbientField.makeStarShell`) so they
    /// parallax with the camera; this flat backdrop stays starless.
    private func makeSpaceBackground() -> NSImage {
        let size = NSSize(width: 2048, height: 2048)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // Solid darkest base first — guarantees full coverage, no uncovered corner.
        let base = NSColor(hex: "#04060D")!
        base.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        // Soft, off-center vignette. Ending on `base` (and filling past the end
        // radius with it) means the gradient dissolves into the corners with no
        // visible ring.
        let vignette = NSGradient(
            colors: [NSColor(hex: "#0C1322")!, NSColor(hex: "#070A14")!, base],
            atLocations: [0, 0.55, 1],
            colorSpace: .sRGB
        )!
        let focus = NSPoint(x: size.width * 0.42, y: size.height * 0.60)
        vignette.draw(fromCenter: focus, radius: 0,
                      toCenter: focus, radius: size.width * 0.85,
                      options: [.drawsAfterEndingLocation])

        // Faint nebula washes — token-derived hues, screened over the dark so
        // they only ever lighten. Subtle: this is distant gas, not the field.
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        func nebula(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ color: NSColor, _ alpha: CGFloat) {
            let g = NSGradient(
                starting: color.withAlphaComponent(alpha),
                ending: color.withAlphaComponent(0)
            )!
            g.draw(fromCenter: NSPoint(x: cx, y: cy), radius: 0,
                   toCenter: NSPoint(x: cx, y: cy), radius: radius, options: [])
        }
        nebula(size.width * 0.28, size.height * 0.74, size.width * 0.46, MapPalette.npc, 0.10)
        nebula(size.width * 0.76, size.height * 0.34, size.width * 0.52, MapPalette.sensing, 0.07)
        nebula(size.width * 0.58, size.height * 0.84, size.width * 0.30, MapPalette.accent, 0.05)
        ctx.restoreGState()

        return image
    }

    /// Resolve the ambient field's hues from design tokens (dark appearance), so
    /// the interstellar medium stays on-palette without hard-coded color.
    private func ambientTints() -> AmbientField.Tints {
        func rgb(_ color: NSColor) -> SIMD3<Float> {
            let c = color.usingColorSpace(.sRGB) ?? color
            return SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
        }
        return AmbientField.Tints(
            dustWarm: rgb(MapPalette.resource),
            dustCool: rgb(MapPalette.transit),
            nebula: [
                rgb(MapPalette.npc),
                rgb(MapPalette.sensing),
                rgb(MapPalette.life),
                rgb(MapPalette.transit),
                rgb(MapPalette.relayPurple),
            ],
            protostar: rgb(MapPalette.accent)
        )
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
        // The star shell is the skybox — it stays put as you drill into a system.
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
            node.setLabelVisible(show || node.system.isCurrentLocation || node.system.id == currentSelection)
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
