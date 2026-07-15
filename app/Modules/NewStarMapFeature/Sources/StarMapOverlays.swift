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

/// One leg of a route: its endpoints as full LOCATION codes (belt/planet/Lagrange/…)
/// and its duration. At galaxy scale each endpoint resolves to its system's star, so an
/// intra-system cruise leg collapses to a point (the ship parks at the star) while a
/// surge/jump leg spans two stars.
struct RouteLeg: Equatable {
    var from: String
    var to: String
    var seconds: Double?
}

/// A ship in transit, with its per-leg route and the real trip window so the renderer
/// can place it at the correct point along the (multi-leg) trajectory at any instant.
struct ShipRoute: Equatable {
    /// The device in transit — carried through to the renderer's `Ship` so the
    /// tappable overlay icon can identify which device a pip represents.
    var deviceCode: String
    /// Overall origin system designation (e.g. `SOL`) — anchors the drawn ribbon.
    var from: String
    /// Overall destination system designation.
    var to: String
    /// When the trip began.
    var departedAt: Date
    /// When the trip completes (final arrival).
    var arrivesAt: Date
    /// The route's legs (location-level), in order. Empty falls back to a single
    /// straight `from`→`to` segment over the whole window.
    var legs: [RouteLeg]
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
