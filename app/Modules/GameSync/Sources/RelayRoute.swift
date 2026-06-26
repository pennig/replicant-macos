//
//  RelayRoute.swift
//  Replicould — GameSync
//
//  The unit of registration for relay ingestion, modeled on
//  `SessionLifecycleHandler`: a feature (via the app composition root) hands
//  `GameSync` a route that says "for relay events of this top-level `type`, do
//  this." `GameSync` itself stays feature-agnostic — it never parses a payload
//  or names a feature table; it only switches on `UnifiedEvent.type` and
//  dispatches to the matching route. This keeps every event→row mapping in one
//  place (the route's `apply`), so an evolving relay payload is a localized edit.
//

import API
import ComposableArchitecture
import Foundation

/// A handler for one top-level relay event `type` ("event" / "message" /
/// "bobnet"). Identified by `id` so re-registering replaces rather than
/// duplicates (mirroring `SessionLifecycleHandler`).
public struct RelayRoute: Sendable, Identifiable {
    public let id: String
    /// The `UnifiedEvent.type` this route handles.
    public let type: String
    /// Apply a matching event — typically by reconciling/upserting a row, or
    /// (for a thin event) triggering one authoritative re-read.
    public var apply: @Sendable (UnifiedEvent) async -> Void
    /// Tier-2 gap repair: authoritative catch-up when the relay cursor falls
    /// outside Redis retention (e.g. cold start). Wired up in Phase 2; a no-op
    /// until then.
    public var gapRepair: @Sendable () async -> Void

    public init(
        id: String,
        type: String,
        apply: @escaping @Sendable (UnifiedEvent) async -> Void,
        gapRepair: @escaping @Sendable () async -> Void = {}
    ) {
        self.id = id
        self.type = type
        self.apply = apply
        self.gapRepair = gapRepair
    }
}

/// Dispatches a `UnifiedEvent` to every registered route whose `type` matches.
/// Split out from `GameSync` so routing is unit-testable without the relay.
struct RelayRouter: Sendable {
    let routes: LockIsolated<[RelayRoute]>

    func dispatch(_ event: UnifiedEvent) async {
        for route in routes.value where route.type == event.type {
            await route.apply(event)
        }
    }
}
