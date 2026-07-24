import simd

// The pure half of the label pass: project every star, cull off-screen, rank by
// nearness, and pick the zoom-gated curated set (+ the selection, always
// labelled). Extracted from `StarFieldRenderer.encodeLabels` so it can run OFF
// the main thread — it is O(stars) + a sort, the label subsystem's dominant cost,
// and it needs nothing but value-type snapshots (star field + camera pose). The
// main-thread side keeps only what is inherently main-bound: texture
// rasterization (`LabelTextureCache`) and the tiny collision layout over the
// ~20 survivors.
//
// Pure + deterministic → unit-testable. The math mirrors the shaders exactly
// (star_vertex's system-focus recession and angular-size clamp), so a label's
// anchor is frame-locked to its star's rendered position.

// `nonisolated`: the module defaults to MainActor isolation, but this namespace
// exists precisely to run OFF the main actor (from a detached task).
nonisolated enum LabelSelection {
    /// The camera pose + viewport for one selection pass, in pixels.
    struct Camera: Sendable {
        var view: float4x4
        var projection: float4x4
        var width: Float
        var height: Float
        var eye: SIMD3<Float>
    }

    /// The star-field snapshot the projection reads. Mirrors the renderer's
    /// system-focus recession inputs so labels track pushed stars.
    struct Field: Sendable {
        var positions: [SIMD3<Float>]
        var worldRadii: [Float]
        var focusedStar: Int?
        var orreryReveal: Float
        var orreryCenter: SIMD3<Float>
        var systemPush: Float
        var minAngularSize: Float
        var maxAngularSize: Float
        var ringFloor: Float
    }

    /// One chosen star: its index, screen point (pixels), eye distance, and the
    /// pixel radius of its reticle ring (the label anchors just below the ring).
    struct Choice: Equatable, Sendable {
        var index: Int
        var screen: SIMD2<Float>
        var distance: Float
        var ringRadius: Float
    }

    /// Project a star and return its screen placement, or nil when behind the
    /// camera / off-screen. Mirrors `star_vertex`'s recession + size clamp.
    static func project(_ i: Int, field: Field, camera: Camera) -> Choice? {
        var world = field.positions[i]
        if i != field.focusedStar, field.orreryReveal > 0 {
            let toStar = world - field.orreryCenter
            world = field.orreryCenter + toStar * (1 + field.systemPush * field.orreryReveal)
        }
        let vpos = camera.view * SIMD4<Float>(world, 1)
        let clip = camera.projection * vpos
        if clip.w <= 0 { return nil }                  // behind the camera
        let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
        if abs(ndc.x) > 1.1 || abs(ndc.y) > 1.1 { return nil }
        let px = SIMD2<Float>((ndc.x * 0.5 + 0.5) * camera.width,
                              (0.5 - ndc.y * 0.5) * camera.height)
        let camDist = simd_length(vpos.xyz)
        let rv = min(max(field.worldRadii[i], camDist * field.minAngularSize),
                     camDist * field.maxAngularSize)
        let ys = camera.projection.columns.1.y        // = 1/tan(fovy/2), for pixel sizing
        let starPixels = ys * rv / clip.w * (camera.height * 0.5)
        let ringR = max(starPixels * 1.3, field.ringFloor)
        return Choice(index: i, screen: px,
                      distance: simd_length(world - camera.eye), ringRadius: ringR)
    }

    /// The curated label set: the nearest `budget` on-screen stars, plus the
    /// selected star (always labelled, ranked first by the caller's priority).
    static func choose(field: Field, camera: Camera, budget: Int, selected: Int?) -> [Choice] {
        var onscreen: [Choice] = []
        onscreen.reserveCapacity(min(field.positions.count, 256))
        for i in field.positions.indices {
            if let c = project(i, field: field, camera: camera) { onscreen.append(c) }
        }
        onscreen.sort { $0.distance < $1.distance }

        var chosen = Array(onscreen.prefix(max(budget, 0)))
        if let selected, !chosen.contains(where: { $0.index == selected }),
           field.positions.indices.contains(selected),
           var c = project(selected, field: field, camera: camera) {
            c.distance = 0                             // the selection outranks everything
            chosen.append(c)
        }
        return chosen
    }
}
