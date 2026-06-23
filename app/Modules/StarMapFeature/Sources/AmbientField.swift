//
//  AmbientField.swift
//  StarMapFeature
//
//  The ~6000-star deep-space backdrop, baked into ONE point-primitive geometry
//  (one draw call) rather than a node per star. The shape is a deterministic
//  barred-spiral + central bulge, seeded so the galaxy renders identically
//  every launch and is snapshot/unit-testable.
//

import SceneKit

/// A small, deterministic linear-congruential RNG (ported from the prototype's
/// `makeStars`). A `Sendable` value type so field generation is pure.
public struct SeededLCG: Sendable {
    private var state: UInt32

    public init(seed: UInt32) {
        self.state = seed == 0 ? 0x9E3779B9 : seed
    }

    /// Next value in [0, 1).
    public mutating func next() -> Double {
        state = state &* 1_103_515_245 &+ 12_345
        state &= 0x7FFF_FFFF
        return Double(state) / Double(0x7FFF_FFFF)
    }

    /// Next value in [low, high).
    public mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}

enum AmbientField {

    /// Tunables for the field's shape (scene units).
    struct Config {
        var starCount = 6000
        var radius: Double = 260          // outer disc radius — surrounds the charted set
        var bulgeFraction = 0.30          // share of stars in the core bulge
        var bulgeRadius: Double = 70
        var arms = 2                      // barred spiral arms
        var armWindings = 2.4             // turns from core to rim
        var armSpread = 0.55              // angular scatter around an arm (rad)
        var discThickness: Double = 26    // vertical extent of the disc
        var bulgeThickness: Double = 46
    }

    /// Build the field node. Deterministic in `seed`.
    static func makeNode(seed: UInt32 = 0xBADC0FFE, config: Config = Config()) -> SCNNode {
        var rng = SeededLCG(seed: seed)
        var vertices: [SCNVector3] = []
        var colorComponents: [Float] = []  // flat rgba per vertex
        vertices.reserveCapacity(config.starCount)
        colorComponents.reserveCapacity(config.starCount * 4)

        // Two warm/cool poles: a warm amber core fading to a cool violet-blue rim.
        let core = (r: 1.00, g: 0.86, b: 0.62)
        let rim  = (r: 0.64, g: 0.70, b: 1.00)

        for _ in 0..<config.starCount {
            let inBulge = rng.next() < config.bulgeFraction
            let p: SCNVector3
            let radialT: Double  // 0 at core … 1 at rim, for color/brightness

            if inBulge {
                // Central bulge: dense, roughly spheroidal, biased toward center.
                let rr = pow(rng.next(), 1.8) * config.bulgeRadius
                let theta = rng.next(in: 0...(2 * .pi))
                p = SCNVector3(
                    cos(theta) * rr,
                    rng.next(in: -1...1) * config.bulgeThickness * pow(1 - rr / config.bulgeRadius, 0.6),
                    sin(theta) * rr
                )
                radialT = rr / config.radius
            } else {
                // Spiral arm: log-ish spiral with angular scatter, thinning outward.
                let arm = Int(rng.next() * Double(config.arms))
                let t = sqrt(rng.next())                 // bias stars outward a touch
                let rr = t * config.radius
                let base = t * config.armWindings * 2 * .pi
                let armOffset = Double(arm) / Double(config.arms) * 2 * .pi
                let scatter = (rng.next() - 0.5) * config.armSpread * (1.2 - t * 0.5)
                let angle = base + armOffset + scatter
                p = SCNVector3(
                    cos(angle) * rr,
                    rng.next(in: -1...1) * config.discThickness * (1 - t * 0.5),
                    sin(angle) * rr
                )
                radialT = t
            }

            vertices.append(p)

            // Color: lerp core→rim by radius; brightness (alpha) twinkles.
            let mix = min(1, max(0, radialT))
            let brightness = rng.next(in: 0.18...0.85)
            colorComponents.append(Float(core.r + (rim.r - core.r) * mix))
            colorComponents.append(Float(core.g + (rim.g - core.g) * mix))
            colorComponents.append(Float(core.b + (rim.b - core.b) * mix))
            colorComponents.append(Float(brightness))
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let colorData = colorComponents.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )

        let indices = (0..<vertices.count).map { UInt32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 3.2
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 4.0

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant       // unlit — vertex color is the look
        material.isLitPerPixel = false
        material.writesToDepthBuffer = false      // a backdrop: never occludes systems
        material.readsFromDepthBuffer = false
        material.blendMode = .add                 // soft additive glow
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "ambientField"
        node.castsShadow = false
        node.renderingOrder = -10                 // draw first, behind everything
        return node
    }
}
