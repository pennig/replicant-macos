import Metal
import simd

// The rendering brain, in one small object.
//
// Every focus behavior we care about — select, search, plot a route, toggle the
// FTL mesh — is the same operation: WRITE this field. The terrain shader READS
// it. Overlays are just writers. Two kinds of concern combine differently:
//   • EMPHASIS (focus, mesh) MAX-combine — a star lit by any of them stays lit.
//   • a data FILTER MASKS the result (multiplies) — it's a restriction, so it
//     takes precedence and can dim even a focused star's neighbourhood.
// The state clamp then wins over everything. No active concern → plain terrain 1.0.
//
// `current` eases toward `target` every frame so a toggle reads as the map
// "focusing" rather than a hard snap. Values floor near-invisible (not zero):
// receded terrain must stay present for depth and stay honest as a click target.

final class RelevanceField {
    /// A distinct thing that wants to write relevance. `focus`/`mesh` are emphasis
    /// (max-combined); `filter` is a restriction (masks the result). New emphasis
    /// overlays add cases; a new restriction would combine like `filter`.
    enum Concern: Hashable { case focus, mesh, filter }

    private let count: Int
    private var current: [Float]
    private var target: [Float]
    private(set) var buffer: MTLBuffer

    // Active concerns' contributions, max-combined into `target`.
    private var contributions: [Concern: [Float]] = [:]
    // State-tier stars (player / ships) that must never dim, whatever the
    // reference overlays want. A CLAMP applied after combining — NOT a writer,
    // because a writer's "0 elsewhere" would wrongly dim the field when it's the
    // only active concern (Invariant 2: state always wins, and only over itself).
    private var clamped: Set<Int> = []

    /// Where fully de-emphasized terrain settles. Not zero — see note above.
    var floor: Float = 0.04
    /// Easing rate (fraction closed per frame at 60fps-ish). ~200–300ms feel.
    var easing: Float = 0.18

    private var positions: [SIMD3<Float>]

    init?(device: MTLDevice, positions: [SIMD3<Float>]) {
        count = positions.count
        self.positions = positions
        current = [Float](repeating: 1, count: count)
        target  = [Float](repeating: 1, count: count)
        guard let buf = device.makeBuffer(length: count * MemoryLayout<Float>.stride,
                                          options: .storageModeShared) else { return nil }
        buffer = buf
        upload()
    }

    /// Set (or clear, with nil) a concern's per-star contribution, then recombine.
    /// This is the one entry point overlays use — the whole write contract.
    func write(_ concern: Concern, _ values: [Float]?) {
        if let values { contributions[concern] = values }
        else { contributions.removeValue(forKey: concern) }
        recompute()
    }

    /// Pin a set of state-tier stars (player / ships) to full relevance — they can
    /// never be dimmed by any overlay. Applied as a clamp, not a contribution.
    func setStateClamp(_ indices: Set<Int>) {
        clamped = indices
        recompute()
    }

    private func recompute() {
        // Emphasis concerns (focus, mesh) MAX-combine — a star lit by any of them
        // stays lit. A data FILTER is a restriction, not an emphasis: it MASKS the
        // result (multiplies), so it takes precedence and can dim even a focused
        // star's neighbourhood. The state clamp then wins over everything.
        let emphasis = contributions.compactMap { $0.key == .filter ? nil : $0.value }
        target = Self.combined(emphasis, count: count)
        if let filter = contributions[.filter] {
            for i in 0..<count { target[i] *= filter[i] }
        }
        for i in clamped where i >= 0 && i < count { target[i] = 1 }
    }

    /// Max-combine active contributions; plain terrain (all 1.0) when none active.
    static func combined(_ contributions: [[Float]], count: Int) -> [Float] {
        guard !contributions.isEmpty else { return [Float](repeating: 1, count: count) }
        var out = [Float](repeating: 0, count: count)
        for c in contributions {
            for i in 0..<count where c[i] > out[i] { out[i] = c[i] }
        }
        return out
    }

    /// Clear the click-focus concern (other concerns, e.g. the mesh, stay).
    func clearFocus() {
        write(.focus, nil)
    }

    /// Focus on one star; relevance falls off by spatial distance to the floor.
    /// (Stand-in for the graph-distance falloff we want once a real graph exists
    /// — same shape, different distance metric.)
    func focus(on index: Int, falloffRadius: Float = 40) {
        let p = positions[index]
        var c = [Float](repeating: floor, count: count)
        for i in 0..<count {
            let d = distance(positions[i], p)
            let t = 1 - min(d / falloffRadius, 1)     // 1 at the star, 0 past the radius
            c[i] = floor + (1 - floor) * (t * t)      // ease-in falloff
        }
        c[index] = 1
        write(.focus, c)
    }

    /// Advance the easing. Returns true while still animating (so the view can
    /// keep redrawing, then settle).
    @discardableResult
    func step() -> Bool {
        var moving = false
        for i in 0..<count {
            let c = current[i], t = target[i]
            let d = t - c
            if abs(d) > 0.001 {
                current[i] = c + d * easing
                moving = true
            } else {
                current[i] = t
            }
        }
        if moving { upload() }
        return moving
    }

    private func upload() {
        current.withUnsafeBytes { src in
            buffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
    }
}
