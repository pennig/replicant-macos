import simd

// A ship in transit — state-tier data (HANDOFF §2 tier 3). Travel is a DIRECT
// point-to-point trajectory between two systems (HANDOFF §1: not constrained to
// the mesh), so a ship is just its two endpoint systems plus where it is along
// the straight line between them. Position is a pure function of time, so it's
// deterministic and testable; the renderer feeds it the clock each frame.

struct Ship {
    /// Endpoint systems (indices into the star array). Both are state-clamped so
    /// they never dim, and both anchor the trajectory.
    let fromStar: Int
    let toStar: Int
    /// One-way trip duration in seconds (demo pacing; the game uses a real ETA).
    var tripDuration: Double
    /// Phase offset in [0,1) so multiple ships aren't in lockstep.
    var phase: Double

    /// Progress 0…1 along the trajectory at `time`, looping.
    func progress(at time: Double) -> Float {
        let p = (time / max(tripDuration, 1e-4) + phase).truncatingRemainder(dividingBy: 1)
        return Float(p < 0 ? p + 1 : p)
    }

    /// Current world position, interpolating between the two systems.
    func position(at time: Double, stars: [Star]) -> SIMD3<Float> {
        let a = stars[fromStar].position, b = stars[toStar].position
        return a + (b - a) * progress(at: time)
    }
}
