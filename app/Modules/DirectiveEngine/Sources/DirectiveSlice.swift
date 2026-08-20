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

/// Self-join alias for the correlated audit anti-join in `readAll`.
private enum ClosingCompletion: AliasName {}

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

    /// Bind size for every `.in(...)` list built from directive targets —
    /// comfortably under SQLite's legacy 999-variable limit. Not `private`,
    /// so a test can size its fixture off the real value.
    static let inListChunkSize = 500

    /// Runs `fetch` once per `inListChunkSize`-sized slice of `values`,
    /// concatenating the results — keeps one `.in(...)` binding under SQLite's
    /// variable-count limit no matter how large the union of targets grows.
    private static func fetchChunked<Row>(
        _ values: Set<String>, fetch: (_ chunk: [String]) throws -> [Row]
    ) throws -> [Row] {
        let ordered = Array(values)
        var rows: [Row] = []
        for start in stride(from: 0, to: ordered.count, by: inListChunkSize) {
            let chunk = Array(ordered[start..<min(start + inListChunkSize, ordered.count)])
            rows.append(contentsOf: try fetch(chunk))
        }
        return rows
    }

    /// One directive-scoped read of the fields the shared `core` cannot
    /// answer. Call inside the same `database.read { db in … }` block as
    /// `WorldCore.read`, same as `WorldView.read`.
    public static func read(from db: Database, core: WorldCore, directive: Directive) throws -> DirectiveSlice {
        try readAll(from: db, core: core, directives: [directive])[directive.id] ?? .empty
    }

    /// `read`, batched: one bounded LIMIT query per directive for `log`, plus a
    /// fixed handful of batched queries for the other four fields — a single
    /// query cannot express a per-directive LIMIT without reading everything.
    public static func readAll(
        from db: Database, core: WorldCore, directives: [Directive]
    ) throws -> [String: DirectiveSlice] {
        guard !directives.isEmpty else { return [:] }
        // `[String?]` matches the nullable `directiveID` column; see
        // `Brain.report`'s identical cast.
        let ids: [String?] = directives.map(\.id)

        // One bounded query per directive: a single batched query can't
        // express a per-directive LIMIT without reading every row across all.
        var logsByDirective: [String: [DirectiveLogEntry]] = [:]
        for directive in directives {
            logsByDirective[directive.id] = try Array(
                DirectiveLogEntry
                    .where { $0.directiveID.eq(directive.id) }
                    .order { $0.occurredAt.desc() }
                    .limit(WorldSnapshot.logWindow)
                    .fetchAll(db)
                    .reversed()
            )
        }

        // Only entries naming a NULL-owner mission op — an owned one is
        // already attributed via `operation.directiveID.in(ids)` below.
        let nullOwnedMissionOpIDs = GameModels.Operation
            .where { $0.directiveID.is(nil) && $0.kind.in(WorldSnapshot.dispatchedKinds) }
            .select(\.id)
        let dispatchRows = try DirectiveLogEntry
            .where {
                $0.directiveID.in(ids)
                    && $0.kind.eq(DirectiveLogKind.commandDispatched)
                    && $0.operationID.isNot(nil)
                    && ($0.operationID ?? "").in(nullOwnedMissionOpIDs)
            }
            .order { $0.occurredAt }
            .fetchAll(db)
        let dispatchByDirective = Dictionary(grouping: dispatchRows) { $0.directiveID ?? "" }
        let dispatchedIDsByDirective = dispatchByDirective.mapValues { Set($0.compactMap(\.operationID)) }

        // Correlated on BOTH directiveID and operationID — see
        // `app/.claude/memory/dispatched-operations-two-set-union.md`.
        let auditRows = try DirectiveLogEntry
            .where { entry in
                entry.directiveID.in(ids)
                    && entry.kind.eq(DirectiveLogKind.commandDispatched)
                    && entry.operationID.isNot(nil)
                    && !DirectiveLogEntry.as(ClosingCompletion.self)
                        .where { completion in
                            completion.directiveID.eq(entry.directiveID)
                                && completion.kind.eq(DirectiveLogKind.opCompleted)
                                && completion.operationID.eq(entry.operationID)
                        }
                        .exists()
            }
            .order { $0.occurredAt }
            .fetchAll(db)
        let auditByDirective = Dictionary(grouping: auditRows) { $0.directiveID ?? "" }

        // Ids the batch dispatched — one unexecuted subquery, never a
        // host-parameter list in Swift.
        let dispatchedIDsSubquery = DirectiveLogEntry
            .where {
                $0.directiveID.in(ids)
                    && $0.kind.eq(DirectiveLogKind.commandDispatched)
                    && $0.operationID.isNot(nil)
            }
            .select { $0.operationID ?? "" }

        // Mission half: kinds a machine reads. Owner column is truth; log
        // is the fallback for rows written before it existed.
        let missionOps = try GameModels.Operation
            .where { operation in
                (operation.directiveID.in(ids) || operation.id.in(dispatchedIDsSubquery))
                    && operation.kind.in(WorldSnapshot.dispatchedKinds)
            }
            .fetchAll(db)
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

        let details = try fetchChunked(allDecoded) { chunk in
            try SystemDetail.where { $0.designation.in(chunk) }.fetchAll(db)
        }
        // A blob that fails to decode is treated as absent: the mission
        // then can't prove the target is scanned and surveys it again,
        // which is the safe direction to be wrong in.
        let decodedSystems = details.reduce(into: [String: StarSystem]()) { systems, detail in
            if let system = try? detail.system() { systems[detail.designation] = system }
        }

        let assays = try fetchChunked(allWanted) { chunk in
            try SiteAssay.where { $0.system.in(chunk) }.fetchAll(db)
        }

        var result: [String: DirectiveSlice] = [:]
        for directive in directives {
            let directiveID = directive.id
            let log = logsByDirective[directiveID] ?? []

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
