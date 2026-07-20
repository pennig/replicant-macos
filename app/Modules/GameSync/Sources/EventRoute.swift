//
//  EventRoute.swift
//  Replicould — GameSync
//
//  The unit of registration for event ingestion, modeled on
//  `SessionLifecycleHandler`: a feature (via the app composition root) hands
//  `GameSync` a route that says "for events matching this, do this." `GameSync`
//  itself stays feature-agnostic — it never names a feature table; it only
//  matches on the event's dotted-name taxonomy and dispatches to the matching
//  route. This keeps every event→row mapping in one place (the route's `apply`),
//  so an evolving taxonomy is a localized edit.
//

import API
import ComposableArchitecture
import Foundation
import GameServices
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

/// Selects which events a route handles, over the dotted taxonomy
/// (`category` = `"mining"`, `event` = `"mining.started"`).
public enum EventMatcher: Sendable {
    /// Every event in a coarse family, e.g. `.category("bobnet")`.
    case category(String)
    /// One exact dotted name, e.g. `.event("relay.activated")`.
    case event(String)
    /// A dotted-name prefix, e.g. `.eventPrefix("travel.")`.
    case eventPrefix(String)
    /// Every event (the device confirm-read route uses this).
    case all

    /// Whether this route is the catch-all — used to detect events that only the
    /// device route handled (i.e. have no feature-specific route yet).
    var isCatchAll: Bool { if case .all = self { return true } else { return false } }

    func matches(_ event: GameEventEnvelope) -> Bool {
        switch self {
        case .category(let category): return event.category == category
        case .event(let name): return event.event == name
        case .eventPrefix(let prefix): return event.event.hasPrefix(prefix)
        case .all: return true
        }
    }
}

/// A handler for a set of events (matched by `match`). Identified by `id` so
/// re-registering replaces rather than duplicates (mirroring
/// `SessionLifecycleHandler`).
public struct EventRoute: Sendable, Identifiable {
    public let id: String
    /// Which events this route handles.
    public let match: EventMatcher
    /// Apply a matching event — typically by reconciling/upserting a row, or (for
    /// a thin event) triggering one authoritative re-read.
    public var apply: @Sendable (GameEventEnvelope) async -> Void
    /// Tier-2 gap repair: authoritative catch-up a route owns for its channel,
    /// run on (re)start. Default no-op.
    public var gapRepair: @Sendable () async -> Void

    public init(
        id: String,
        match: EventMatcher,
        apply: @escaping @Sendable (GameEventEnvelope) async -> Void,
        gapRepair: @escaping @Sendable () async -> Void = {}
    ) {
        self.id = id
        self.match = match
        self.apply = apply
        self.gapRepair = gapRepair
    }
}

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
