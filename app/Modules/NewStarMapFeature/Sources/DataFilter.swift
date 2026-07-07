import simd

// Data-filter overlays — the "filter by resource / life / scan" focus behavior
// from the HANDOFF, expressed (like every overlay) as a WRITER to the relevance
// field. Picking a filter lights the systems that match and lets the rest recede,
// max-combined with any active mesh or focus. Pure: turns per-system data into a
// per-star relevance contribution, so it's testable without the GPU.

enum DataFilter: CaseIterable {
    case life, minerals, gas, rare, unexplored

    var label: String {
        switch self {
        case .life: "Life"
        case .minerals: "Minerals"
        case .gas: "Gas"
        case .rare: "Rare elements"
        case .unexplored: "Unexplored"
        }
    }

    /// The 0…1 metric this filter reads from a system (graded, so richer/more
    /// developed systems read brighter; binary for the scan filter).
    func metric(_ star: Star) -> Float {
        switch self {
        case .life: return star.life.normalized
        case .minerals: return star.resources.minerals
        case .gas: return star.resources.gas
        case .rare: return star.resources.rare
        case .unexplored: return star.scan == .unexplored ? 1 : 0
        }
    }

    /// Per-star relevance contribution: matching systems toward full, the rest
    /// toward `floor` (receded, never invisible — an honest, still-clickable field).
    func relevance(for stars: [Star], floor: Float) -> [Float] {
        stars.map { floor + (1 - floor) * metric($0) }
    }
}
