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

@MainActor
final class SystemNode: SCNNode {
    let system: GalaxySystem

    private let starNode = SCNNode()
    private let labelNode = SCNNode()
    private let halo = SCNNode()
    private var layerNodes: [InfoLayer: SCNNode] = [:]

    /// The lazily-built orrery (Phase 2). Created on first drill-in, then kept.
    private(set) var orrery: OrreryNode?

    private var baseRadius: CGFloat { system.isHome ? 2.8 : 1.7 }

    init(system: GalaxySystem) {
        self.system = system
        super.init()
        name = "system:\(system.id)"
        position = SCNVector3(system.position.x, system.position.y, system.position.z)
        buildStar()
        buildHalo()
        buildLabel()
        buildInfoLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Build

    private var starColor: NSColor {
        system.isHome ? MapPalette.accent : MapPalette.star(hex: system.star.color)
    }

    private func buildStar() {
        let sphere = SCNSphere(radius: baseRadius)
        sphere.segmentCount = 24
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = starColor
        m.emission.contents = starColor
        // Aware-only systems glow dimmer (recon.dim), so the field reads at a glance.
        m.emission.intensity = CGFloat(system.recon.dim) * (system.isHome ? 1.3 : 1.0)
        sphere.materials = [m]
        starNode.geometry = sphere
        starNode.name = "star:\(system.id)"
        addChildNode(starNode)
    }

    private func buildHalo() {
        let torus = SCNTorus(ringRadius: baseRadius + 2.4, pipeRadius: 0.22)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = MapPalette.accent
        m.emission.contents = MapPalette.accent
        torus.materials = [m]
        halo.geometry = torus
        halo.name = "halo:\(system.id)"
        halo.constraints = [SCNBillboardConstraint()]
        halo.opacity = 0
        halo.isHidden = true
        addChildNode(halo)
    }

    private func buildLabel() {
        let text = SCNText(string: system.name, extrusionDepth: 0)
        text.font = .monospacedSystemFont(ofSize: 8, weight: .semibold)
        text.flatness = 0.25
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = MapPalette.textPrimary
        m.emission.contents = MapPalette.textPrimary
        text.materials = [m]
        labelNode.geometry = text

        // Center horizontally, anchor just above the star.
        let (lo, hi) = text.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, lo.y, 0)
        labelNode.scale = SCNVector3(0.42, 0.42, 0.42)
        labelNode.position = SCNVector3(0, baseRadius + 3.2, 0)
        labelNode.constraints = [SCNBillboardConstraint()]
        labelNode.name = "label:\(system.id)"
        addChildNode(labelNode)
    }

    /// Build only the info-layer markers that apply to this system. Each is
    /// hidden until its layer is toggled on. Rings sit around the star; pips
    /// cluster just off it. Schematic, data-viz forward — no imagery.
    private func buildInfoLayers() {
        if system.presence == .mine {
            layerNodes[.presence] = makeRing(radius: baseRadius + 1.3, color: MapPalette.accent)
        }
        if system.presence == .npc {
            layerNodes[.npc] = makeRing(radius: baseRadius + 1.3, color: MapPalette.npc)
        }
        if system.hasRelay {
            layerNodes[.relay] = makeRing(radius: baseRadius + 3.4, color: MapPalette.accent, pipe: 0.14)
        }
        // Recon pip — always meaningful; brightness encodes the state.
        let reconPip = makePip(color: MapPalette.textTertiary, size: 0.7, angle: .pi * 0.5)
        reconPip.opacity = CGFloat(system.recon.dim)
        layerNodes[.recon] = reconPip
        if system.lifeTier != nil {
            layerNodes[.life] = makePip(color: MapPalette.life,
                                        size: 0.5 + 0.18 * CGFloat(system.lifeTier!.tier),
                                        angle: .pi * 0.18)
        }
        if system.resourceRichness > 0.01 {
            layerNodes[.resource] = makePip(color: MapPalette.resource,
                                            size: 0.4 + 0.7 * CGFloat(system.resourceRichness),
                                            angle: -.pi * 0.18)
        }
        for node in layerNodes.values { node.isHidden = true }
    }

    private func makeRing(radius: CGFloat, color: NSColor, pipe: CGFloat = 0.18) -> SCNNode {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: pipe)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        torus.materials = [m]
        let node = SCNNode(geometry: torus)
        node.constraints = [SCNBillboardConstraint()]
        addChildNode(node)
        return node
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
        let r = baseRadius + 1.8
        node.position = SCNVector3(cos(angle) * r, sin(angle) * r, 0)
        node.constraints = [SCNBillboardConstraint()]  // keep cluster facing camera
        addChildNode(node)
        return node
    }

    // MARK: - Apply state

    /// Show/hide markers for the active layer set.
    func apply(activeLayers: Set<InfoLayer>) {
        for (layer, node) in layerNodes {
            node.isHidden = !activeLayers.contains(layer)
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
    func setLabelVisible(_ visible: Bool) {
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

    /// Grow the star into the lit sun and clear galaxy chrome. Call inside the
    /// camera's SCNTransaction so the grow animates with the fly-in.
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
        starNode.geometry?.firstMaterial?.emission.intensity =
            CGFloat(system.recon.dim) * (system.isHome ? 1.3 : 1.0)
        apply(activeLayers: activeLayers)
        labelNode.isHidden = false
    }
}
