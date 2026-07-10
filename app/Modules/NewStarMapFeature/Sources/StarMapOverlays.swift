import Foundation
import GameModels

// The live overlays the renderer draws on top of the star terrain, beyond what a
// single `Star` can carry: the FTL mesh links (pairs of systems) and the ships in
// transit (trajectories between systems). Current-location and relay-membership
// are folded into `Star` (single-star flags) so the terrain identity already
// reflects them; these two are relationships/state that don't belong on one star.
//
// The value is `Equatable` so `MetalStarView` rebuilds the renderer only when the
// real data actually changes — not on every redraw. Ship *positions* animate
// per-frame inside the renderer from the timestamps here, so a moving ship does
// not churn this value.

/// A ship in transit between two star systems, with the real trip window so the
/// renderer can place it at the correct point along the straight-line trajectory
/// at any instant.
struct ShipRoute: Equatable {
    /// Origin system designation (e.g. `SOL`).
    var from: String
    /// Destination system designation.
    var to: String
    /// When the trip began.
    var departedAt: Date
    /// When the trip completes (final arrival).
    var arrivesAt: Date
}

/// Everything the renderer overlays on the terrain that isn't expressible as a
/// per-star flag: the FTL mesh links and the ships in transit.
struct StarMapOverlays: Equatable {
    /// Undirected FTL mesh links as system-designation pairs, from the backend's
    /// relay network view. Endpoints not present in the charted terrain are
    /// ignored when the renderer resolves them.
    var ftlLinks: [FTLLink]
    /// Ships currently in transit, from the live device roster's travel blocks.
    var ships: [ShipRoute]

    static let empty = StarMapOverlays(ftlLinks: [], ships: [])
}
