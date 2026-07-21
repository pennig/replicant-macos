//
//  EventRouter.swift
//  Replicould — GameSync
//
//  The dispatch side of event ingestion. The `EventRoute`/`EventMatcher`
//  types live in `GameServices` so owning modules can declare routes next to
//  the tables and clients they drive; this router is the engine that fans a
//  received envelope out to them, logs every event at the single choke point,
//  and persists the diagnostic `EventLog` ledger.
//

import API
import Dependencies
import Foundation
import GameServices
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

/// Dispatches a `GameEventEnvelope` to every registered route whose matcher
/// accepts it. Split out from `GameSync` so routing is unit-testable without the
/// stream.
struct EventRouter: Sendable {
    let routes: LockIsolated<[EventRoute]>

    func dispatch(_ event: GameEventEnvelope) async {
        let matches = routes.value.filter { $0.match.matches(event) }

        // Event logging is first-class here, at the single choke point: EVERY
        // event is logged with its name/category/provenance and raw payload, so
        // the taxonomy can be filled in from live traffic.
        let provenance = event.provenance == .stream ? "stream" : "catchUp"
        logger.info("event \(event.event, privacy: .public) [\(provenance, privacy: .public)] device=\(event.deviceCode ?? "-", privacy: .public) \(Self.payloadString(event), privacy: .public)")

        // Loudly surface an event that no *feature-specific* route consumes AND
        // that carries no device code — the device confirm-read route (`.all`)
        // legitimately handles device-scoped events generically, so those aren't
        // "unhandled", but a non-device event nothing recognizes is worth flagging
        // so a new/unknown event name announces itself for follow-up.
        let hasSpecificRoute = matches.contains { !$0.match.isCatchAll }
        if !hasSpecificRoute, event.deviceCode == nil {
            logger.notice("⚠️ UNHANDLED EVENT \(event.event, privacy: .public) (category=\(event.category, privacy: .public)) id=\(event.id, privacy: .public) \(Self.payloadString(event), privacy: .public)")
        }

        // Persist every event to the diagnostic `EventLog` ledger. `isHandled` is
        // the exact inverse of the "unhandled" condition above, so the in-app flag
        // matches this dispatcher's own notion. Best-effort and no-op in tests.
        @Dependency(\.eventLogClient) var eventLogClient
        let isHandled = hasSpecificRoute || event.deviceCode != nil
        let matchedRouteIDs = matches.filter { !$0.match.isCatchAll }.map(\.id)
        await eventLogClient.record(event, isHandled, matchedRouteIDs)

        for route in matches {
            await route.apply(event)
        }
    }

    /// Run each route's tier-2 gap repair: authoritative catch-up a route owns for
    /// its channel, run on (re)start. Routes with no tier-2 keep the default
    /// no-op, so this is a cheap fan-out over the (small) route set.
    func runGapRepair() async {
        for route in routes.value {
            await route.gapRepair()
        }
    }

    /// Compact JSON rendering of an event's payload for logs (never throws).
    private static func payloadString(_ event: GameEventEnvelope) -> String {
        guard let payload = event.payload, !payload.isEmpty else { return "payload={}" }
        guard
            let data = try? JSONEncoder().encode(payload),
            let json = String(data: data, encoding: .utf8)
        else { return "payload=<unencodable>" }
        return "payload=\(json)"
    }
}
