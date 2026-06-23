//
//  AmbientField.swift
//  StarMapFeature
//
//  The diffuse interstellar medium that sits *between* the charted systems —
//  the systems themselves are the galaxy; this is the stuff in between. Baked
//  into ONE point-primitive geometry (one draw call) rather than a node per
//  mote, it layers a faint dust haze, a few abstract nebula clouds, and a
//  scatter of hot proto-star masses across a volume far larger than the charted
//  set. Deterministic in `seed`, so it renders identically every launch and is
//  snapshot/unit-testable.
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

    /// Approximately normal value (mean 0, std ≈ 0.58) via the central-limit
    /// trick — cheap, deterministic, good enough for soft clustering.
    public mutating func gaussian() -> Double {
        (next() + next() + next() + next()) * 0.5 - 1.0
    }
}

enum AmbientField {

    /// On-palette hues for the medium, resolved from design tokens by the caller
    /// (the field generator is pure and off the main actor, so colors come in).
    struct Tints: Sendable {
        var dustWarm: SIMD3<Float>
        var dustCool: SIMD3<Float>
        var nebula: [SIMD3<Float>]
        var protostar: SIMD3<Float>

        /// Neutral fallback so `makeNode` stays callable without a token context
        /// (previews, snapshots). Muted, desaturated — not real UI chrome.
        static let neutral = Tints(
            dustWarm: SIMD3(0.62, 0.58, 0.50),
            dustCool: SIMD3(0.46, 0.54, 0.72),
            nebula: [
                SIMD3(0.62, 0.50, 0.86),   // violet
                SIMD3(0.40, 0.74, 0.78),   // teal
                SIMD3(0.46, 0.80, 0.56),   // green
                SIMD3(0.46, 0.62, 0.92),   // blue
            ],
            protostar: SIMD3(1.00, 0.78, 0.48)   // warm amber
        )
    }

    /// Tunables for the field (scene units). The charted systems span a radius of
    /// ~95 units; this field is an order of magnitude larger so it surrounds and
    /// permeates them rather than reading as a galaxy in its own right.
    struct Config {
        var dustCount = 7000              // diffuse haze filling the volume
        var nebulaCount = 20              // abstract gas clouds
        var nebulaPointsEach = 1200
        var protostarCount = 120          // hot masses not yet stars
        var radius: Double = 5000         // overall field extent (≫ charted set)
        var thickness: Double = 5000      // vertical extent — puffy, not a thin disc
    }

    /// Build the field node. Deterministic in `seed`.
    static func makeNode(
        seed: UInt32 = 0xBADC0FFE,
        config: Config = Config(),
        tints: Tints = .neutral
    ) -> SCNNode {
        var rng = SeededLCG(seed: seed)
        let total = config.dustCount + config.nebulaCount * config.nebulaPointsEach + config.protostarCount
        var vertices: [SCNVector3] = []
        var colorComponents: [Float] = []  // flat rgba per vertex
        vertices.reserveCapacity(total)
        colorComponents.reserveCapacity(total * 4)

        func emit(_ p: SCNVector3, _ rgb: SIMD3<Float>, _ alpha: Float) {
            vertices.append(p)
            colorComponents.append(rgb.x)
            colorComponents.append(rgb.y)
            colorComponents.append(rgb.z)
            colorComponents.append(alpha)
        }

        // — Dust haze: a flattened, lumpy ellipsoid of dim motes. Mild center
        //   bias so it thins toward the edges and fades into the backdrop. —
        for _ in 0..<config.dustCount {
            let theta = rng.next(in: 0...(2 * .pi))
            let rr = pow(rng.next(), 0.55) * config.radius          // spread outward
            let flatten = 1 - 0.45 * (rr / config.radius)           // thinner at the rim
            let p = SCNVector3(
                cos(theta) * rr,
                rng.gaussian() * config.thickness * flatten,
                sin(theta) * rr
            )
            let mix = Float(rng.next())
            let rgb = mix * tints.dustWarm + (1 - mix) * tints.dustCool
            emit(p, rgb, Float(rng.next(in: 0.03...0.16)))          // faint
        }

        // — Nebula clouds: a handful of soft gaussian blobs, each a single token
        //   hue. These are the abstractions of gas/nebulae between systems. —
        for cloud in 0..<config.nebulaCount {
            let centerTheta = rng.next(in: 0...(2 * .pi))
            let centerR = rng.next(in: config.radius * 0.12 ... config.radius * 0.82)
            let centerX = cos(centerTheta) * centerR
            let centerY = rng.gaussian() * config.thickness * 1.1
            let centerZ = sin(centerTheta) * centerR
            let spread = rng.next(in: config.radius * 0.10 ... config.radius * 0.22)
            let tint = tints.nebula.isEmpty ? tints.dustCool : tints.nebula[cloud % tints.nebula.count]
            for _ in 0..<config.nebulaPointsEach {
                let p = SCNVector3(
                    centerX + rng.gaussian() * spread,
                    centerY + rng.gaussian() * spread * 0.6,   // a touch flatter
                    centerZ + rng.gaussian() * spread
                )
                // Slight per-mote brightness variation keeps clouds billowy.
                let v = Float(rng.next(in: 0.55...1.0))
                emit(p, tint * v, Float(rng.next(in: 0.06...0.30)))
            }
        }

        // — Proto-stars: a few hot, bright masses seeded inside the clouds. Their
        //   high alpha lets the camera bloom catch them as embedded glints. —
        for _ in 0..<config.protostarCount {
            let theta = rng.next(in: 0...(2 * .pi))
            let rr = rng.next(in: 0 ... config.radius * 0.7)
            let p = SCNVector3(
                cos(theta) * rr + rng.gaussian() * 12,
                rng.gaussian() * config.thickness * 0.7,
                sin(theta) * rr + rng.gaussian() * 12
            )
            // Whiten the hottest ones toward the core for a forming-star look.
            let heat = Float(rng.next())
            let rgb = tints.protostar * (1 - 0.35 * heat) + SIMD3(repeating: 0.35 * heat)
            emit(p, rgb, Float(rng.next(in: 0.6...1.0)))
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
        // Larger world point size with a soft screen-space cap reads as billowy
        // gas up close yet stays a fine haze when the whole field is in frame.
        element.pointSize = 2.5
        element.minimumPointScreenSpaceRadius = 0.5
        element.maximumPointScreenSpaceRadius = 6.0

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant       // unlit — vertex color is the look
        material.isLitPerPixel = false
        material.writesToDepthBuffer = false      // a backdrop: never occludes systems
        material.readsFromDepthBuffer = false
        // Screen (not additive): a soft glow that saturates gracefully toward the
        // mote color instead of summing to a blown-out white wash when the whole
        // field compresses into the frame at full zoom-out.
        material.blendMode = .screen
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "ambientField"
        node.castsShadow = false
        node.renderingOrder = -10                 // draw first, behind everything
        return node
    }

    /// A distant shell of faint stars on a large sphere — the universe beyond.
    /// Real 3D geometry (not a flat backdrop), so it parallaxes as the camera
    /// orbits. Alpha-blended and dim, it never accumulates or blooms.
    static func makeStarShell(
        seed: UInt32 = 0xCAFE_BABE,
        count: Int = 900,
        radius: Double = 2600
    ) -> SCNNode {
        var rng = SeededLCG(seed: seed)
        var vertices: [SCNVector3] = []
        var colorComponents: [Float] = []
        vertices.reserveCapacity(count)
        colorComponents.reserveCapacity(count * 4)

        for _ in 0..<count {
            // Uniform points on a sphere.
            let z = rng.next(in: -1...1)
            let theta = rng.next(in: 0...(2 * .pi))
            let ring = (1 - z * z).squareRoot()
            vertices.append(SCNVector3(cos(theta) * ring * radius, z * radius, sin(theta) * ring * radius))
            // Faint, slightly cool-to-warm white.
            let warm = Float(rng.next())
            colorComponents.append(0.86 + 0.14 * warm)
            colorComponents.append(0.88 + 0.10 * warm)
            colorComponents.append(1.0 - 0.10 * warm)
            colorComponents.append(Float(rng.next(in: 0.20...0.85)))
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
        element.pointSize = 2.0
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 2.5

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isLitPerPixel = false
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.blendMode = .alpha               // dim points, no accumulation
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "starShell"
        node.castsShadow = false
        node.renderingOrder = -20                 // behind the ambient field
        return node
    }
}
