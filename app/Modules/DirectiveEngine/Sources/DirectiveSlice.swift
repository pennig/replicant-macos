//
//  DirectiveSlice.swift
//  Replicould — DirectiveEngine
//
//  The half of a world read that DOES depend on which directive is asking:
//  the five fields scoped to one directive's log, dispatches and targets.
//  Read once per directive against the tick's shared `WorldCore`. See
//  `WorldCore.swift` for the other half.
//

import Foundation
import GameModels
import SQLiteData
import UniverseModels

/// The directive-scoped half of `WorldSnapshot` — composed with `WorldCore`
/// by `WorldSnapshot.init(core:slice:now:)`.
public struct DirectiveSlice: Equatable, Sendable {
    public let log: [DirectiveLogEntry]
    public let auditLog: [DirectiveLogEntry]
    public let dispatchedOperations: [String: GameModels.Operation]
    public let systems: [String: StarSystem]
    public let siteAssays: [String: [String: Double]]

    public init(
        log: [DirectiveLogEntry],
        auditLog: [DirectiveLogEntry],
        dispatchedOperations: [String: GameModels.Operation],
        systems: [String: StarSystem],
        siteAssays: [String: [String: Double]]
    ) {
        self.log = log
        self.auditLog = auditLog
        self.dispatchedOperations = dispatchedOperations
        self.systems = systems
        self.siteAssays = siteAssays
    }

    /// One directive-scoped read of the fields the shared `core` cannot
    /// answer. Call inside the same `database.read { db in … }` block as
    /// `WorldCore.read`, same as `WorldView.read`.
    public static func read(from db: Database, core: WorldCore, directive: Directive) throws -> DirectiveSlice {
        // Assays are scoped to every target — one small row each, and a roam
        // planner ranks across the whole tour.
        let baseWanted = Set(directive.targets)
            .union(directive.originDesignation.map { [$0] } ?? [])
        // Blobs are scoped to the CURRENT target only. Every reader of
        // `systems` asks about `directive.currentTarget`, never a later one,
        // and a roaming run's target list grows without bound — at a few
        // hundred targets, decoding one blob each dominated the whole read.
        let baseDecoded = Set(directive.currentTarget.map { [$0] } ?? [])
            .union(directive.originDesignation.map { [$0] } ?? [])
        let directiveID = directive.id
        let vesselCode = directive.deviceCode

        // Newest `logWindow` first, then restored to ascending order — the
        // order every caller (`.reversed()` walks included) already expects.
        let log = try Array(DirectiveLogEntry
            .where { $0.directiveID.eq(directiveID) }
            .order { $0.occurredAt.desc() }
            .limit(WorldSnapshot.logWindow)
            .fetchAll(db)
            .reversed())

        // Matched in SQL, not Swift — see
        // `app/.claude/memory/dispatched-operations-two-set-union.md`.
        let auditLog = try DirectiveLogEntry
            .where { entry in
                entry.directiveID.eq(directiveID)
                    && entry.kind.eq(DirectiveLogKind.commandDispatched)
                    && entry.operationID.isNot(nil)
                    && (entry.operationID ?? "").notIn(
                        DirectiveLogEntry
                            .where {
                                $0.directiveID.eq(directiveID)
                                    && $0.kind.eq(DirectiveLogKind.opCompleted)
                                    && $0.operationID.isNot(nil)
                            }
                            .select { $0.operationID ?? "" }
                    )
            }
            .order { $0.occurredAt }
            .fetchAll(db)

        // Ids this directive dispatched — one query, never a
        // host-parameter list in Swift.
        let dispatchedIDs = DirectiveLogEntry
            .where {
                $0.directiveID.eq(directiveID)
                    && $0.kind.eq(DirectiveLogKind.commandDispatched)
                    && $0.operationID.isNot(nil)
            }
            .select { $0.operationID ?? "" }

        // Mission half: kinds a machine reads. Owner column is truth; log
        // is the fallback for rows written before it existed.
        let missionOps = try GameModels.Operation
            .where { operation in
                (operation.directiveID.eq(directiveID) || operation.id.in(dispatchedIDs))
                    && operation.kind.in(WorldSnapshot.dispatchedKinds)
            }
            .fetchAll(db)

        // Audit half, kept kind-agnostic on purpose. See
        // `app/.claude/memory/dispatched-operations-two-set-union.md`.
        let auditOperationIDs = auditLog.compactMap(\.operationID)
        let auditOps = auditOperationIDs.isEmpty
            ? []
            : try GameModels.Operation.where { $0.id.in(auditOperationIDs) }.fetchAll(db)

        let dispatched = Dictionary(
            (missionOps + auditOps).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var wanted = baseWanted
        var decoded = baseDecoded
        if let vessel = core.devices[vesselCode],
           let location = vessel.location {
            // The arrival check reads the system the vessel is in now.
            wanted.insert(SiteAssay.system(of: location))
            decoded.insert(SiteAssay.system(of: location))
        }
        let details = try SystemDetail
            .where { $0.designation.in(Array(decoded)) }
            .fetchAll(db)
        let systems = details.reduce(into: [String: StarSystem]()) { systems, detail in
            // A blob that fails to decode is treated as absent: the mission
            // then can't prove the target is scanned and surveys it again,
            // which is the safe direction to be wrong in.
            if let system = try? detail.system() { systems[detail.designation] = system }
        }

        // Same `wanted` scope as the system blobs above — never the whole
        // table. `SiteAssay.system` is exactly the leading-segment
        // designation `wanted` is built from (`SiteAssay.system(of:)`).
        let assays = try SiteAssay
            .where { $0.system.in(Array(wanted)) }
            .fetchAll(db)
        let siteAssays = Dictionary(assays.map { ($0.id, $0.totals) }, uniquingKeysWith: { _, last in last })

        return DirectiveSlice(
            log: log,
            auditLog: auditLog,
            dispatchedOperations: dispatched,
            systems: systems,
            siteAssays: siteAssays
        )
    }
}
