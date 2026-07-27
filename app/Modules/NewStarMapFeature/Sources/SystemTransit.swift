//
//  SystemTransit.swift
//  NewStarMapFeature
//
//  Pure, deterministic resolver for the inbound / outbound travel affordance: given a
//  ship's ordered route (location codes, origin → final destination) and a predicate for
//  "does this code resolve to a visible anchor at the layer I'm viewing?", it finds where
//  the route CROSSES THE BOUNDARY of the current view and describes the callout(s) to
//  draw there — plus the in-view anchors to trace with the dotted connector.
//
//  No SwiftUI / GPU / clock → unit-testable in isolation. The renderer supplies the
//  predicate (`OrreryLayout.position(ofLocation:) != nil` at the active layer) and turns
//  the result into risers, connectors, and floating callouts.
//

/// One boundary crossing of a route relative to the current view — a place to plant a
/// riser + callout.
struct TransitBoundary: Equatable {
    enum Direction: Equatable { case inbound, outbound }

    /// The device in transit — carried to the callout so a tap can select it.
    var deviceCode: String
    /// The route location where the riser sits (resolves at the current layer).
    var anchorCode: String
    /// WHERE that anchor sits in `orderedCodes`. `orderedCodes[i]` is the route's
    /// origin at `i == 0` and leg `i - 1`'s destination otherwise, so this is what
    /// lets a caller name the leg whose boundary the callout marks — and it stays
    /// unambiguous when a route names the same code twice.
    var anchorIndex: Int
    /// Inbound = the route arrives into this view from elsewhere; outbound = it leaves.
    var direction: Direction
    /// The far end the callout names: the route's origin (inbound) or final dest (outbound).
    var endpointCode: String
    /// The immediate external waypoint just outside the view, if distinct from `endpointCode`
    /// (nil for a direct two-location hop where via would just repeat the endpoint).
    var viaCode: String?
}

/// The result of resolving one ship's route against the current view.
struct TransitResult: Equatable {
    /// Zero, one (inbound OR outbound), or two (pass-through) boundary callouts.
    var boundaries: [TransitBoundary]
    /// The in-view anchors, in route order, to trace with the dotted connector. Fewer than
    /// two ⇒ nothing to connect (just the riser + callout).
    var connectorCodes: [String]

    static let none = TransitResult(boundaries: [], connectorCodes: [])
}

enum SystemTransit {
    /// Resolve a ship's ordered route (origin → final destination, all waypoints) against
    /// the current view's `resolves` predicate. See `TransitResult`.
    ///
    /// - An **inbound** boundary exists when the first in-view anchor isn't the route's
    ///   origin (something upstream isn't shown here); the riser sits on that first anchor
    ///   and the callout names the origin (via the immediate upstream waypoint).
    /// - An **outbound** boundary exists when the last in-view anchor isn't the route's
    ///   final destination; the riser sits on that last anchor and the callout names the
    ///   destination (via the immediate downstream waypoint).
    /// - The connector traces the in-view anchors between those ends.
    static func resolve(orderedCodes: [String], deviceCode: String,
                        resolves: (String) -> Bool) -> TransitResult {
        let n = orderedCodes.count
        guard n > 0 else { return .none }

        let resolvable = orderedCodes.indices.filter { resolves(orderedCodes[$0]) }
        guard let firstR = resolvable.first, let lastR = resolvable.last else { return .none }

        var boundaries: [TransitBoundary] = []

        // Inbound: something upstream of the first in-view anchor isn't shown here.
        if firstR > 0 {
            let origin = orderedCodes[0]
            let via = orderedCodes[firstR - 1]
            boundaries.append(TransitBoundary(
                deviceCode: deviceCode,
                anchorCode: orderedCodes[firstR],
                anchorIndex: firstR,
                direction: .inbound,
                endpointCode: origin,
                viaCode: via == origin ? nil : via))
        }

        // Outbound: something downstream of the last in-view anchor isn't shown here.
        if lastR < n - 1 {
            let dest = orderedCodes[n - 1]
            let via = orderedCodes[lastR + 1]
            boundaries.append(TransitBoundary(
                deviceCode: deviceCode,
                anchorCode: orderedCodes[lastR],
                anchorIndex: lastR,
                direction: .outbound,
                endpointCode: dest,
                viaCode: via == dest ? nil : via))
        }

        // The connector traces every in-view anchor from the first to the last, in order.
        let connector = resolvable.map { orderedCodes[$0] }
        return TransitResult(boundaries: boundaries, connectorCodes: connector)
    }
}
