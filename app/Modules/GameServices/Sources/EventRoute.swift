//
//  EventRoute.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The unit of registration for event ingestion, modeled on
//  `SessionLifecycleHandler`: a route says "for events matching this, do
//  this." The `GameSync` engine consumes routes but never names a feature
//  table; it only matches on the event's dotted-name taxonomy and dispatches.
//
//  The type lives here — one tier below the engine — so the modules that OWN
//  an ingestion policy can declare their routes next to the tables and clients
//  those routes drive (`MessagesIngestion`, `LocationsIngestion`, …), and the
//  composition root shrinks to registration calls. This keeps every event→row
//  mapping in one place (the route's `apply`), so an evolving taxonomy is a
//  localized edit.
//

import API
import Foundation

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
    public var isCatchAll: Bool { if case .all = self { return true } else { return false } }

    public func matches(_ event: GameEventEnvelope) -> Bool {
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
