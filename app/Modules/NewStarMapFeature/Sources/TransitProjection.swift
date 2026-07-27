import CoreGraphics
import SwiftUI

// The bridge that carries transit-callout anchor positions (the top of each dotted riser)
// out of the Metal render loop into the SwiftUI overlay, so the inbound/outbound cards can
// track their risers per-frame. Mirrors `ShipProjection`: the renderer projects each
// callout's world anchor with the SAME camera matrices it feeds the GPU, so a card is
// frame-locked to its riser even as bodies orbit and the camera moves.
//
// Only `TransitCalloutLayer` reads `TransitProjectionModel.callouts`; the parent map view
// merely holds the model and hands it down, so a per-frame mutation invalidates just the
// overlay — never the map view (whose `body` builds the whole star terrain). Keeping that
// observation boundary is load-bearing for performance.

/// One transit callout's on-screen placement: the device it represents, whether the route
/// is inbound/outbound here, the far endpoint + immediate external waypoint it names, when
/// it crosses this view's boundary, its screen point (view POINTS, top-left origin), and an
/// opacity tracking the orrery reveal.
struct ProjectedTransit: Equatable, Identifiable {
    enum Direction: Equatable { case inbound, outbound }

    let deviceCode: String
    let direction: Direction
    /// The far end named by the card: origin (inbound) or final destination (outbound).
    let endpointCode: String
    /// The immediate external waypoint, if distinct from `endpointCode`.
    let viaCode: String?
    /// When the device crosses THIS view's boundary — arrives at the anchor
    /// (inbound) or departs it (outbound). Drives the card's live countdown.
    /// Legs are contiguous with no dwell, so both directions read the same
    /// instant; only the verb differs.
    let eventAt: Date
    let point: CGPoint
    let opacity: Double

    /// Stable per device + direction, so a pass-through route's two cards don't collide.
    var id: String { "\(deviceCode)-\(direction == .inbound ? "in" : "out")" }
}

/// The observable the renderer pushes to each frame and `TransitCalloutLayer` reads.
@MainActor
@Observable
final class TransitProjectionModel {
    var callouts: [ProjectedTransit] = []
}
