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

    /// All five fields empty — what a directive owning no rows of its own
    /// gets back from `readAll`, and `read`'s fallback if its id is somehow
    /// absent from the result.
    public static let empty = DirectiveSlice(
        log: [], auditLog: [], dispatchedOperations: [:], systems: [:], siteAssays: [:]
    )

    /// One directive-scoped read of the fields the shared `core` cannot
    /// answer. Call inside the same `database.read { db in … }` block as
    /// `WorldCore.read`, same as `WorldView.read`.
    public static func read(from db: Database, core: WorldCore, directive: Directive) throws -> DirectiveSlice {
        try readAll(from: db, core: core, directives: [directive])[directive.id] ?? .empty
    }

    /// `read`, batched: every directive's scoped fields in one pass, a fixed
    /// number of queries regardless of directive count. Keyed by
    /// `directive.id`; a directive owning no rows still gets an empty entry.
    public static func readAll(
        from db: Database, core: WorldCore, directives: [Directive]
    ) throws -> [String: DirectiveSlice] {
        guard !directives.isEmpty else { return [:] }
        // `[String?]` matches the nullable `directiveID` column; see
        // `Brain.report`'s identical cast.
        let ids: [String?] = directives.map(\.id)

        // Newest first, then grouped and truncated per directive in Swift —
        // a per-directive LIMIT cannot be expressed in one plain query.
        let logsByDirective = Dictionary(
            grouping: try DirectiveLogEntry
                .where { $0.directiveID.in(ids) }
                .order { $0.occurredAt.desc() }
                .fetchAll(db),
            by: { $0.directiveID ?? "" }
        )

        // Every directive's own dispatch entries, materialized once — the
        // mission-half split and the audit anti-join below both read this.
        let dispatchRows = try DirectiveLogEntry
            .where {
                $0.directiveID.in(ids)
                    && $0.kind.eq(DirectiveLogKind.commandDispatched)
                    && $0.operationID.isNot(nil)
            }
            .order { $0.occurredAt }
            .fetchAll(db)
        let dispatchByDirective = Dictionary(grouping: dispatchRows) { $0.directiveID ?? "" }
        let dispatchedIDsByDirective = dispatchByDirective.mapValues { Set($0.compactMap(\.operationID)) }
        let unionedDispatchedIDs = Array(Set(dispatchRows.compactMap(\.operationID)))

        // Per directive, in Swift — a completion logged by one directive
        // must never exclude another directive's dispatch of the same id.
        let completedIDsByDirective = Dictionary(
            grouping: try DirectiveLogEntry
                .where {
                    $0.directiveID.in(ids)
                        && $0.kind.eq(DirectiveLogKind.opCompleted)
                        && $0.operationID.isNot(nil)
                }
                .fetchAll(db),
            by: { $0.directiveID ?? "" }
        ).mapValues { Set($0.compactMap(\.operationID)) }
        // Matched per directive, not in one SQL statement — see
        // `app/.claude/memory/dispatched-operations-two-set-union.md`.
        var auditByDirective: [String: [DirectiveLogEntry]] = [:]
        for directive in directives {
            let completed = completedIDsByDirective[directive.id] ?? []
            auditByDirective[directive.id] = (dispatchByDirective[directive.id] ?? []).filter {
                guard let opID = $0.operationID else { return false }
                return !completed.contains(opID)
            }
        }

        // Mission half: kinds a machine reads. Owner column is truth; log
        // is the fallback for rows written before it existed.
        let missionOps: [GameModels.Operation]
        if unionedDispatchedIDs.isEmpty {
            missionOps = try GameModels.Operation
                .where { $0.directiveID.in(ids) && $0.kind.in(WorldSnapshot.dispatchedKinds) }
                .fetchAll(db)
        } else {
            missionOps = try GameModels.Operation
                .where { operation in
                    (operation.directiveID.in(ids) || operation.id.in(unionedDispatchedIDs))
                        && operation.kind.in(WorldSnapshot.dispatchedKinds)
                }
                .fetchAll(db)
        }
        let missionOpsByDirective = Dictionary(grouping: missionOps) { $0.directiveID ?? "" }
        let missionOpsByID = Dictionary(missionOps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Audit half, kept kind-agnostic on purpose. See
        // `app/.claude/memory/dispatched-operations-two-set-union.md`.
        let auditOperationIDs = Array(Set(auditByDirective.values.flatMap { $0.compactMap(\.operationID) }))
        let auditOps = auditOperationIDs.isEmpty
            ? []
            : try GameModels.Operation.where { $0.id.in(auditOperationIDs) }.fetchAll(db)
        let auditOpsByID = Dictionary(auditOps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Wanted/decoded designation sets, unioned once for the two batched
        // fetches below, kept per-directive for the split afterward.
        var wantedByDirective: [String: Set<String>] = [:]
        var decodedByDirective: [String: Set<String>] = [:]
        var allWanted = Set<String>()
        var allDecoded = Set<String>()
        for directive in directives {
            // Assays are scoped to every target; blobs to the CURRENT target
            // only — see the field docs on `WorldSnapshot`.
            var wanted = Set(directive.targets).union(directive.originDesignation.map { [$0] } ?? [])
            var decoded = Set(directive.currentTarget.map { [$0] } ?? [])
                .union(directive.originDesignation.map { [$0] } ?? [])
            if let vessel = core.devices[directive.deviceCode], let location = vessel.location {
                // The arrival check reads the system the vessel is in now.
                wanted.insert(SiteAssay.system(of: location))
                decoded.insert(SiteAssay.system(of: location))
            }
            wantedByDirective[directive.id] = wanted
            decodedByDirective[directive.id] = decoded
            allWanted.formUnion(wanted)
            allDecoded.formUnion(decoded)
        }

        let details = try SystemDetail.where { $0.designation.in(Array(allDecoded)) }.fetchAll(db)
        // A blob that fails to decode is treated as absent: the mission
        // then can't prove the target is scanned and surveys it again,
        // which is the safe direction to be wrong in.
        let decodedSystems = details.reduce(into: [String: StarSystem]()) { systems, detail in
            if let system = try? detail.system() { systems[detail.designation] = system }
        }

        let assays = try SiteAssay.where { $0.system.in(Array(allWanted)) }.fetchAll(db)

        var result: [String: DirectiveSlice] = [:]
        for directive in directives {
            let directiveID = directive.id
            let log = Array((logsByDirective[directiveID] ?? []).prefix(WorldSnapshot.logWindow).reversed())

            var dispatched = missionOpsByDirective[directiveID] ?? []
            for opID in dispatchedIDsByDirective[directiveID] ?? [] {
                if let op = missionOpsByID[opID] { dispatched.append(op) }
            }
            let auditLog = auditByDirective[directiveID] ?? []
            for entry in auditLog {
                if let opID = entry.operationID, let op = auditOpsByID[opID] { dispatched.append(op) }
            }
            let dispatchedOperations = Dictionary(
                dispatched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )

            let decoded = decodedByDirective[directiveID] ?? []
            let systems = decodedSystems.filter { decoded.contains($0.key) }

            let wanted = wantedByDirective[directiveID] ?? []
            let siteAssays = Dictionary(
                assays.filter { wanted.contains($0.system) }.map { ($0.id, $0.totals) },
                uniquingKeysWith: { _, last in last }
            )

            result[directiveID] = DirectiveSlice(
                log: log,
                auditLog: auditLog,
                dispatchedOperations: dispatchedOperations,
                systems: systems,
                siteAssays: siteAssays
            )
        }
        return result
    }
}
