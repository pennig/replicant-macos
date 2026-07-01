//
//  SystemNode.swift
//  StarMapFeature
//
//  A charted star as a typed SCNNode. It owns the emissive star sphere, a
//  billboarded label, a selection halo, and a set of info-layer marker nodes
//  toggled by the HUD. This is the node the camera selects in the galaxy; in
//  Phase 2 it gains a lazy `orrery` child and becomes the persistent shared
//  node for the drill-in transition, so it is built never to be reparented.
//

import AppKit
import SceneKit
import UI
import UniverseModels

@MainActor
final class SystemNode: SCNNode {
    let system: GalaxySystem

    private let starNode = SCNNode()
    /// One billboarded container for all flat overlay chrome (label, rings,
    /// halo, pips). Because it tracks the screen, every child is camera-facing
    /// and screen-anchored without needing its own constraint.
    private let overlay = SCNNode()
    private let labelNode = SCNNode()
    private let halo = SCNNode()
    private var layerNodes: [InfoLayer: SCNNode] = [:]
    /// Info layers we've already tried to build (so N/A layers aren't retried).
    private var attemptedLayers: Set<InfoLayer> = []
    private var labelBuilt = false
    /// The last active-layer set, applied to nodes as they're lazily built.
    private var activeLayers: Set<InfoLayer> = []

    /// The lazily-built orrery (Phase 2). Created on first drill-in, then kept.
    private(set) var orrery: OrreryNode?

    /// Galaxy star radius. Kept small so stars read as points among the field;
    /// on drill-in the star grows from here up to the orrery's sun size.
    private let baseRadius: CGFloat = 0.7

    /// Screen radius (pt) at which the lit sphere is swapped for the flat point —
    /// and, equally, the largest the point is ever drawn. Sharing one value for
    /// both means the point enters at exactly the size the sphere left, so the
    /// LOD cutover has no size jump.
    private let pointLODRadius: CGFloat = 14

    init(system: GalaxySystem) {
        self.system = system
        super.init()
        name = "system:\(system.id)"
        position = SCNVector3(system.position.x, system.position.y, system.position.z)
        // Star + halo are cheap and eager; the label and info-layer markers are
        // built lazily (on first reveal / first time their layer is toggled on)
        // so a galaxy of thousands of stars stays cheap to populate.
        buildStar()
        buildOverlay()
        buildHalo()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Build

    private var starColor: NSColor {
        system.isCurrentLocation ? MapPalette.accent : MapPalette.starColor(spectralType: system.star.spectralType)
    }

    private var starEmission: CGFloat {
        CGFloat(system.recon.dim) * (system.isCurrentLocation ? 1.0 : 0.5)
    }

    private func buildStar() {
        let sphere = SCNSphere(radius: baseRadius)
        sphere.segmentCount = 16
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = starColor
        m.emission.contents = starColor
        // Aware-only systems glow dimmer (recon.dim), so the field reads at a glance.
        m.emission.intensity = starEmission
        sphere.materials = [m]

        // LOD: past a modest distance the lit sphere is sub-pixel and barely
        // readable, so swap to a screen-space point with a minimum radius. It
        // stays a crisp, readable dot at any distance for ~nothing per draw.
        sphere.levelsOfDetail = [
            SCNLevelOfDetail(geometry: makeStarPoint(color: starColor), screenSpaceRadius: pointLODRadius),
        ]

        starNode.geometry = sphere
        starNode.name = "star:\(system.id)"
        addChildNode(starNode)
    }

    /// A single screen-space point that never shrinks below a couple of pixels —
    /// the distant-LOD stand-in for the star sphere.
    private func makeStarPoint(color: NSColor) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: [SCNVector3(0, 0, 0)])
        let element = SCNGeometryElement(indices: [UInt32(0)], primitiveType: .point)
        // pointSize is in local (world) units, not pixels — so the point projects
        // smaller with distance just like the sphere did. SceneKit's point
        // projection doesn't map 1:1 to the sphere's bounding radius, though, so a
        // diameter-matched point reads visibly smaller at the cutover. Instead,
        // size it generously so its projected radius is already pinned at the
        // `pointLODRadius` cap at the moment of the swap: the point then enters at
        // exactly the size the sphere left (no jump) and shrinks from there to the
        // 2.5pt floor. This is the knob to nudge if the cutover ever reads off.
        element.pointSize = baseRadius * 2.1
        element.minimumPointScreenSpaceRadius = 2.5
        element.maximumPointScreenSpaceRadius = pointLODRadius
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.emission.intensity = starEmission
        m.writesToDepthBuffer = false
        m.blendMode = .add
        geometry.materials = [m]
        return geometry
    }

    /// The shared billboarded container. Sits at the star's center; the single
    /// constraint here serves every overlay child.
    private func buildOverlay() {
        overlay.name = "overlay:\(system.id)"
        overlay.constraints = [cameraFacingBillboard()]
        addChildNode(overlay)
    }

    private func buildHalo() {
        let torus = SCNTorus(ringRadius: baseRadius + 2.4, pipeRadius: 0.22)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = MapPalette.accent
        m.emission.contents = MapPalette.accent
        torus.materials = [m]
        // The torus ring lies in XZ; tilt it into the overlay's XY (screen)
        // plane so the shared billboard shows it face-on as a circle.
        halo.geometry = torus
        halo.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        halo.name = "halo:\(system.id)"
        halo.opacity = 0
        halo.isHidden = true
        overlay.addChildNode(halo)
    }

    private func buildLabelIfNeeded() {
        guard !labelBuilt else { return }
        labelBuilt = true
        let text = SCNText(string: system.name, extrusionDepth: 0)
        text.font = .monospacedSystemFont(ofSize: 8, weight: .semibold)
        text.flatness = 0.25
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = MapPalette.textPrimary
        m.emission.contents = MapPalette.textPrimary
        text.materials = [m]

        // The overlay tracks the screen, so offsetting the glyph *down in local
        // space* keeps the label screen-down (visually beneath the star) at any
        // camera pitch. Pivot at the glyph's top-center so it grows downward.
        labelNode.geometry = text
        let (lo, hi) = text.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, hi.y, 0)
        // Sized to sit just under the small galaxy star, not dwarf it.
        labelNode.scale = SCNVector3(0.12, 0.12, 0.12)
        labelNode.position = SCNVector3(0, -(baseRadius + 0.7), 0)
        labelNode.renderingOrder = 10
        labelNode.name = "label:\(system.id)"
        overlay.addChildNode(labelNode)
    }

    /// Build the marker for one info layer, if it applies to this system. Each
    /// is created lazily the first time its layer is switched on, so an
    /// idle/unlayered galaxy of thousands of stars costs nothing. Rings sit
    /// around the star; pips cluster just off it — schematic, no imagery.
    private func makeLayerNode(_ layer: InfoLayer) -> SCNNode? {
        switch layer {
        case .presence where system.presence == .mine:
            return makeRing(radius: baseRadius + 1.3, color: MapPalette.accent)
        case .npc where system.presence == .npc:
            return makeRing(radius: baseRadius + 1.3, color: MapPalette.npc)
        case .relay where system.hasRelay:
            return makeRing(radius: baseRadius + 3.4, color: MapPalette.accent, pipe: 0.14)
        case .recon:
            // Always meaningful; brightness encodes the state.
            let pip = makePip(color: MapPalette.textTertiary, size: 0.7, angle: .pi * 0.5)
            pip.opacity = CGFloat(system.recon.dim)
            return pip
        case .life:
            guard let tier = system.lifeTier else { return nil }
            return makePip(color: MapPalette.life, size: 0.5 + 0.18 * CGFloat(tier.tier), angle: .pi * 0.18)
        case .resource where system.resourceRichness > 0.01:
            return makePip(color: MapPalette.resource,
                           size: 0.4 + 0.7 * CGFloat(system.resourceRichness), angle: -.pi * 0.18)
        default:
            return nil
        }
    }

    private func makeRing(radius: CGFloat, color: NSColor, pipe: CGFloat = 0.18) -> SCNNode {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: pipe)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        torus.materials = [m]
        // Tilt the torus from its native XZ plane into the overlay's XY (screen)
        // plane so the shared billboard reads it as a circle around the star.
        let node = SCNNode(geometry: torus)
        node.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        overlay.addChildNode(node)
        return node
    }

    /// A billboard constraint free on all axes — keeps the overlay (and thus all
    /// its flat chrome) fully face-on to the camera at any orbit angle.
    private func cameraFacingBillboard() -> SCNBillboardConstraint {
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        return billboard
    }

    private func makePip(color: NSColor, size: CGFloat, angle: CGFloat) -> SCNNode {
        let sphere = SCNSphere(radius: size)
        sphere.segmentCount = 12
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        sphere.materials = [m]
        let node = SCNNode(geometry: sphere)
        // Positioned in the overlay's screen plane, so the cluster stays pinned
        // around the star on screen regardless of camera angle.
        let r = baseRadius + 1.8
        node.position = SCNVector3(cos(angle) * r, sin(angle) * r, 0)
        overlay.addChildNode(node)
        return node
    }

    // MARK: - Apply state

    /// Show/hide markers for the active layer set, building each marker lazily
    /// the first time its layer is switched on.
    func apply(activeLayers: Set<InfoLayer>) {
        self.activeLayers = activeLayers
        for layer in InfoLayer.allCases {
            let active = activeLayers.contains(layer)
            if active && !attemptedLayers.contains(layer) {
                attemptedLayers.insert(layer)
                if let node = makeLayerNode(layer) { layerNodes[layer] = node }
            }
            layerNodes[layer]?.isHidden = !active
        }
    }

    /// Toggle the pulsing selection halo.
    func setSelected(_ selected: Bool) {
        if selected {
            halo.isHidden = false
            halo.removeAllActions()
            let pulse = SCNAction.sequence([
                .fadeOpacity(to: 0.9, duration: 0.7),
                .fadeOpacity(to: 0.35, duration: 0.7),
            ])
            halo.runAction(.repeatForever(pulse), forKey: "pulse")
        } else {
            halo.removeAllActions()
            halo.runAction(.sequence([.fadeOut(duration: 0.25), .hide()]))
        }
    }

    /// Distance-based label culling, driven by the scene's render-loop pass.
    /// Builds the label lazily on first reveal.
    func setLabelVisible(_ visible: Bool) {
        if visible { buildLabelIfNeeded() }
        labelNode.isHidden = !visible
    }

    // MARK: - Orrery / system mode (Phase 2)

    /// Build the orrery once, as a child of this (persistent) star node.
    func buildOrreryIfNeeded(model: SystemModel) {
        guard orrery == nil else { return }
        let node = OrreryNode(model: model)
        orrery = node
        addChildNode(node)
    }

    /// Grow the star into the lit sun and clear galaxy chrome. The star scales up
    /// from its (small) galaxy size to the orrery's sun size — a deliberate grow
    /// on the fly-in. Call inside the camera's SCNTransaction so it animates.
    func enterSystemMode(sunRadiusScene: Double) {
        let target = CGFloat(sunRadiusScene) / baseRadius
        starNode.scale = SCNVector3(target, target, target)
        starNode.geometry?.firstMaterial?.emission.intensity = 1.6
        halo.removeAllActions()
        halo.isHidden = true
        labelNode.isHidden = true
        for node in layerNodes.values { node.isHidden = true }
    }

    /// Shrink the sun back to a galaxy star and restore the active overlays.
    func exitSystemMode(activeLayers: Set<InfoLayer>) {
        starNode.scale = SCNVector3(1, 1, 1)
        starNode.geometry?.firstMaterial?.emission.intensity = starEmission
        apply(activeLayers: activeLayers)
        if labelBuilt { labelNode.isHidden = false }
    }
}
