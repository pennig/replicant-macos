//
//  DirectiveTimeline.swift
//  Replicould — Directives feature
//
//  The detail pane's timeline query, serving BOTH row kinds from one table —
//  the payoff for `DirectiveLogEntry`'s optional `directiveID`/`deviceCode`
//  pair (design spec §2). A custom mission's timeline is keyed by directive; a
//  built-in directive's completion history is keyed by its controller.
//
//  Read-only: the engine and the `directive.*` route write every entry this
//  renders, so watching a run costs nothing but the observation.
//

import Foundation
import GameModels
import SQLiteData

public struct DirectiveTimeline: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public var entries: [DirectiveLogEntry] = []
        public init(entries: [DirectiveLogEntry] = []) { self.entries = entries }
    }

    /// Most entries any one pane renders. A multi-target run accumulates
    /// roughly six per target and nothing prunes the table.
    public static let entryLimit = 100

    public let directiveID: String?
    public let deviceCode: String?

    public init(directiveID: String?, deviceCode: String?) {
        self.directiveID = directiveID
        self.deviceCode = deviceCode
    }

    /// The request for a selected row — one place that knows which id goes in
    /// which slot. The two namespaces must never be mixed: a controller's
    /// history shown under a mission that merely drives it would read as the
    /// mission's own work.
    public static func request(for row: DirectiveRow?) -> DirectiveTimeline {
        switch row {
        case let .custom(directive, _):
            DirectiveTimeline(directiveID: directive.id, deviceCode: nil)
        case let .builtIn(builtIn):
            DirectiveTimeline(directiveID: nil, deviceCode: builtIn.deviceCode)
        case nil:
            DirectiveTimeline(directiveID: nil, deviceCode: nil)
        }
    }

    public func fetch(_ db: Database) throws -> Value {
        // Newest first: a run's interesting end is its latest entry, and the
        // user reading this is watching it happen.
        if let directiveID {
            return Value(entries: try DirectiveLogEntry
                .where { $0.directiveID.eq(directiveID) }
                .order { $0.occurredAt.desc() }
                .limit(Self.entryLimit)
                .fetchAll(db))
        }
        if let deviceCode {
            // `.stepStarted` is excluded deliberately. A custom mission that
            // claims a controller (`MissionAction.assignController`, used by the
            // Survey, Salvage and Haul Runs) stamps that controller's code onto
            // the step entry it writes, so the run's own step-by-step progress
            // carries a `deviceCode` as well as a `directiveID`. Those belong to
            // the MISSION's timeline, not to the controller's own history —
            // rendering "Step: dispatching" under a built-in AMI directive would
            // read as the controller's work, and at one entry per transition
            // they would push real completions past `entryLimit`. Excluding the
            // kind rather than requiring `directiveID IS NULL` keeps a genuinely
            // dual-keyed completion (the `directive.*` route writes both) in both
            // panes, which is the point of the shared table.
            return Value(entries: try DirectiveLogEntry
                .where { $0.deviceCode.eq(deviceCode) && $0.kind.neq(DirectiveLogKind.stepStarted) }
                .order { $0.occurredAt.desc() }
                .limit(Self.entryLimit)
                .fetchAll(db))
        }
        // Nothing selected fetches nothing — never the whole table.
        return Value()
    }
}
