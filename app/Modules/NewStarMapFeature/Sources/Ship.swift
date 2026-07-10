import simd

// A ship in transit — state-tier data (HANDOFF §2 tier 3). Travel is a DIRECT
// point-to-point trajectory between two systems (HANDOFF §1: not constrained to
// the mesh), so a ship is just its two endpoint systems plus where it is along
// the straight line between them. Position is a pure function of time, so it's
// deterministic and testable; the renderer feeds it the clock each frame.
//
// The trip window is expressed in the renderer's monotonic media-time domain
// (the same `CACurrentMediaTime()` clock `draw` runs on). The renderer converts
// the real wall-clock `ShipRoute` timestamps into this domain once, when it's
// built, so per-frame progress is a cheap linear map with no date arithmetic.

struct Ship {
    /// Endpoint systems (indices into the star array). Both are state-clamped so
    /// they never dim, and both anchor the trajectory.
    let fromStar: Int
    let toStar: Int
    /// Trip window in media-time seconds (see file note).
    let departedMedia: Double
    let arrivesMedia: Double

    /// Progress 0…1 along the trajectory at `time`, clamped at the endpoints (a
    /// real trip neither loops nor runs past arrival — an arrived ship simply
    /// sits at its destination until the device roster drops it).
    func progress(at time: Double) -> Float {
        let span = arrivesMedia - departedMedia
        guard span > 1e-4 else { return 1 }
        return Float(min(max((time - departedMedia) / span, 0), 1))
    }

    /// Current world position, interpolating between the two systems.
    func position(at time: Double, stars: [Star]) -> SIMD3<Float> {
        let a = stars[fromStar].position, b = stars[toStar].position
        return a + (b - a) * progress(at: time)
    }
}
