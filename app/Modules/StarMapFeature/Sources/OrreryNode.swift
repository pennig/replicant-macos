//
//  OrreryNode.swift
//  StarMapFeature
//
//  The Star System orrery: 3D bodies on flat (2D) orbital scaffolding, built as
//  a lazy child of a `SystemNode`. Hidden and scaled to zero in galaxy mode; on
//  drill-in it assembles around the star that was already there (rings & HZ
//  first, planets a beat later — see `reveal`).
//
//  Bodies are lit by a sun omni light at the origin; orbit rings, the HZ band,
//  the belt, and courses are unlit/emissive. Orbit motion is driven by repeating
//  SCNActions on each orbit-parent, paused while the orrery is hidden.
//

import AppKit
import SceneKit
import simd
import UI
import UniverseModels

@MainActor
final class OrreryNode: SCNNode {
    private let model: SystemModel
    private let scaffold = SCNNode()   // HZ band · orbit rings · belt · kuiper
    private let bodies = SCNNode()      // planets · moons · lagrange · vessels

    private static let orbitSpeed = 0.6        // seconds of animation per "period day"

    init(model: SystemModel) {
        self.model = model
        super.init()
        name = "orrery"

        buildSunLight()
        buildScaffold()
        buildBodies()
        addChildNode(scaffold)
        addChildNode(bodies)

        // Dormant until revealed.
        isHidden = true
        opacity = 0
        scale = SCNVector3(0.001, 0.001, 0.001)
        bodies.isPaused = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Sun light

    private func buildSunLight() {
        let light = SCNLight()
        light.type = .omni
        light.color = MapPalette.starColor(spectralType: model.star.spectralType)
        light.intensity = 1400
        light.attenuationStartDistance = 4
        light.attenuationEndDistance = 120
        let node = SCNNode()
        node.light = light
        node.name = "sunLight"
        addChildNode(node)
    }

    // MARK: - Scaffold (flat, in the ecliptic plane)

    private func buildScaffold() {
        // Habitable-zone band — a flat green annulus.
        let hz = SCNTube(innerRadius: model.hzInnerScene, outerRadius: model.hzOuterScene, height: 0.05)
        let hzMat = SCNMaterial()
        hzMat.lightingModel = .constant
        hzMat.isDoubleSided = true
        hzMat.diffuse.contents = MapPalette.life
        hzMat.emission.contents = MapPalette.life
        hz.materials = [hzMat]
        let hzNode = SCNNode(geometry: hz)
        hzNode.opacity = 0.10
        scaffold.addChildNode(hzNode)

        // Orbit rings — thin flat tori.
        for planet in model.planets {
            scaffold.addChildNode(makeOrbitRing(radius: planet.semiMajorScene, pipe: 0.04, opacity: 0.5))
        }

        // Asteroid belt — a deterministic point-cloud ring.
        scaffold.addChildNode(makeBeltNode(model.belt))

        // Kuiper ring — faint, on a compressed radius.
        let kuiper = makeOrbitRing(radius: model.kuiperScene, pipe: 0.05, opacity: 0.2)
        scaffold.addChildNode(kuiper)
    }

    private func makeOrbitRing(radius: Double, pipe: Double, opacity: CGFloat) -> SCNNode {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: pipe)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = MapPalette.textTertiary
        m.emission.contents = MapPalette.textTertiary
        torus.materials = [m]
        let node = SCNNode(geometry: torus)
        node.opacity = opacity
        return node
    }

    private func makeBeltNode(_ belt: BeltModel) -> SCNNode {
        var rng = SeededLCG(seed: 0xBE17)
        let count = 220
        var vertices: [SCNVector3] = []
        var colors: [Float] = []
        let color = MapPalette.resource.usingColorSpace(.sRGB) ?? MapPalette.resource
        let (cr, cg, cb) = (Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent))
        for _ in 0..<count {
            let r = belt.innerScene + rng.next() * (belt.outerScene - belt.innerScene)
            let a = rng.next(in: 0...(2 * .pi))
            let y = (rng.next() - 0.5) * 0.8
            vertices.append(SCNVector3(cos(a) * r, y, sin(a) * r))
            let b = Float(rng.next(in: 0.3...0.85))
            colors.append(cr); colors.append(cg); colors.append(cb); colors.append(b)
        }
        let vSource = SCNGeometrySource(vertices: vertices)
        let cData = colors.withUnsafeBytes { Data($0) }
        let cSource = SCNGeometrySource(
            data: cData, semantic: .color, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )
        let element = SCNGeometryElement(indices: (0..<vertices.count).map { UInt32($0) }, primitiveType: .point)
        element.pointSize = 2.0
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [vSource, cSource], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        m.blendMode = .add
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.name = "belt"
        return node
    }

    // MARK: - Bodies (3D, lit by the sun)

    private func buildBodies() {
        for planet in model.planets {
            let orbitParent = SCNNode()
            orbitParent.name = "orbit:\(planet.id)"
            orbitParent.eulerAngles.y = CGFloat(planet.phase0Deg * .pi / 180)

            let planetNode = SCNNode(geometry: litSphere(radius: planet.displayRadius, hex: planet.colorHex))
            planetNode.position = SCNVector3(planet.semiMajorScene, 0, 0)
            planetNode.name = "planet:\(planet.id)"
            orbitParent.addChildNode(planetNode)

            if planet.hasRing {
                planetNode.addChildNode(makePlanetRing(planet.displayRadius, hex: planet.colorHex))
            }
            for moon in planet.moons {
                planetNode.addChildNode(makeMoon(moon))
            }
            if planet.deviceCount > 0 {
                let pip = SCNNode(geometry: emissiveSphere(radius: 0.18, color: MapPalette.accent))
                pip.position = SCNVector3(0, planet.displayRadius + 0.6, 0)
                planetNode.addChildNode(pip)
            }

            // Lagrange points belonging to this planet co-rotate with it.
            for lp in model.lagrange where lp.hostPlanetID == planet.id {
                orbitParent.addChildNode(makeLagrange(lp, hostSemiMajor: planet.semiMajorScene))
            }

            orbitParent.runAction(
                .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: planet.periodDays * Self.orbitSpeed))
            )
            bodies.addChildNode(orbitParent)
        }

        for vessel in model.vessels {
            buildCourseAndVessel(vessel)
        }
    }

    private func litSphere(radius: Double, hex: String) -> SCNSphere {
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 20
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = hex
        m.specular.contents = NSColor(white: 0.4, alpha: 1)
        sphere.materials = [m]
        return sphere
    }

    private func emissiveSphere(radius: Double, color: NSColor) -> SCNSphere {
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 12
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        sphere.materials = [m]
        return sphere
    }

    private func makePlanetRing(_ planetRadius: Double, hex: String) -> SCNNode {
        let torus = SCNTorus(ringRadius: planetRadius * 1.7, pipeRadius: planetRadius * 0.18)
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = hex
        torus.materials = [m]
        let node = SCNNode(geometry: torus)
        node.eulerAngles = SCNVector3(0.45, 0, 0.12)   // a slight tilt
        return node
    }

    private func makeMoon(_ moon: OrreryMoon) -> SCNNode {
        let parent = SCNNode()
        parent.eulerAngles.y = CGFloat(moon.phase0Deg * .pi / 180)
        let moonNode = SCNNode(geometry: litSphere(radius: moon.displayRadius, hex: moon.colorHex))
        moonNode.position = SCNVector3(moon.orbitScene, 0, 0)
        parent.addChildNode(moonNode)
        parent.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: moon.periodDays * Self.orbitSpeed)))
        return parent
    }

    private func makeLagrange(_ lp: LagrangePoint, hostSemiMajor: Double) -> SCNNode {
        // Position within the host's rotating frame (planet sits at angle 0).
        let position: SCNVector3
        switch lp.kind {
        case .inner, .outer:
            position = SCNVector3((lp.t ?? 1) * hostSemiMajor, 0, 0)
        case .trojan:
            let a = (lp.leadDeg ?? 60) * .pi / 180
            position = SCNVector3(cos(a) * hostSemiMajor, 0, sin(a) * hostSemiMajor)
        }
        let hasDevice = lp.deviceType != nil
        let color = hasDevice ? MapPalette.accent : MapPalette.sensing

        // A screen-facing diamond: billboard parent, 45°-rotated plane child.
        let billboard = SCNNode()
        billboard.position = position
        billboard.constraints = [SCNBillboardConstraint()]
        let plane = SCNPlane(width: 0.7, height: 0.7)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.diffuse.contents = color
        m.emission.contents = color
        plane.materials = [m]
        let diamond = SCNNode(geometry: plane)
        diamond.eulerAngles.z = .pi / 4
        diamond.opacity = hasDevice ? 1 : 0.6
        billboard.addChildNode(diamond)
        billboard.name = "lagrange:\(lp.id)"
        return billboard
    }

    // MARK: - Courses & vessels

    private func buildCourseAndVessel(_ vessel: OrreryVessel) {
        let a = model.anchorPosition(for: vessel.fromID)
        let b = model.anchorPosition(for: vessel.toID)
        // Bow the control point radially outward from the star so a course
        // never crosses the sun (spec §05).
        let mid = (a + b) / 2
        let outward = simd_length(mid) > 0.001 ? simd_normalize(mid) : SIMD3<Float>(0, 0, 1)
        let control = mid + outward * Float(8)

        let isHeaven = vessel.name == "HEAVEN"
        let color = isHeaven ? MapPalette.accent : MapPalette.transit

        // Course tube — a faint chain of cylinders along the bezier.
        let course = SCNNode()
        let segments = 16
        var prev = a
        for i in 1...segments {
            let t = Float(i) / Float(segments)
            let point = bezier(a, control, b, t)
            course.addChildNode(cylinder(from: prev, to: point, radius: 0.05, color: color, opacity: 0.4))
            prev = point
        }
        bodies.addChildNode(course)

        // Vessel — a small glowing node parked at its current position.
        let vesselNode = SCNNode(geometry: emissiveSphere(radius: 0.32, color: color))
        vesselNode.simdPosition = bezier(a, control, b, Float(vessel.t))
        vesselNode.name = "vessel:\(vessel.code)"
        bodies.addChildNode(vesselNode)
    }

    private func bezier(_ p0: SIMD3<Float>, _ c: SIMD3<Float>, _ p1: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let u = 1 - t
        return u * u * p0 + 2 * u * t * c + t * t * p1
    }

    private func cylinder(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat, color: NSColor, opacity: CGFloat) -> SCNNode {
        let dir = b - a
        let height = simd_length(dir)
        let geo = SCNCylinder(radius: radius, height: CGFloat(height))
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        geo.materials = [m]
        let node = SCNNode(geometry: geo)
        node.opacity = opacity
        node.simdPosition = (a + b) / 2
        if height > 1e-5 {
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(dir))
        }
        return node
    }

    // MARK: - Reveal / retract

    /// Assemble around the star: scaffold (rings/HZ/belt) reveals with the
    /// container, planets fade in a beat later. Orbits resume.
    func reveal() {
        removeAllActions()
        isHidden = false
        bodies.isPaused = false
        bodies.opacity = 0
        runAction(.group([
            .fadeOpacity(to: 1, duration: 0.5),
            .scale(to: 1, duration: 0.55),
        ]))
        bodies.runAction(.sequence([
            .wait(duration: 0.18),
            .fadeOpacity(to: 1, duration: 0.5),
        ]))
    }

    /// Fold back toward the star and go dormant. Orbits pause once hidden.
    func retract() {
        removeAllActions()
        runAction(.sequence([
            .group([
                .fadeOpacity(to: 0, duration: 0.45),
                .scale(to: 0.001, duration: 0.5),
            ]),
            .hide(),
        ]))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.95))
            self?.bodies.isPaused = true
        }
    }
}
