//
//  DirectiveSliceTests.swift
//  Replicould — DirectiveEngine
//
//  The directive-scoped half of a world read: what each query must EXCLUDE is
//  pinned here as explicitly as what it includes, because a fixture that only
//  lists kept rows cannot fail when a filter is deleted.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

private typealias Operation = GameModels.Operation

private func dispatchEntry(_ id: String, op: String, at: Double) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
        summary: "dispatched \(op)", step: nil, operationID: op, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: at)
    )
}

private func completedEntry(_ id: String, op: String, at: Double) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: .opCompleted,
        summary: "closed \(op)", step: nil, operationID: op, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: at)
    )
}

private func sliceDirective() -> Directive {
    Directive(
        id: "D1", kind: .haulRun, status: .running, deviceCode: "V1",
        targets: ["SOL"], targetIndex: 0, step: "preflight",
        stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite struct AuditLogNarrowing {
    /// A dispatch that already has its `.opCompleted` counterpart is settled
    /// business — re-reading it every tick forever is what made this query
    /// 7,954 rows. Only the UNMATCHED dispatch survives.
    @Test func excludesDispatchesThatAlreadyHaveACompletion() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-SETTLED", at: 1) }.execute(db)
            try DirectiveLogEntry.insert { completedEntry("L2", op: "OP-SETTLED", at: 2) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L3", op: "OP-PENDING", at: 3) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.map(\.id) == ["L3"])
    }

    /// `.opCompleted` rows are the matcher, never the payload: none may appear
    /// in the result, or `recordCompletedOps` would iterate its own output.
    @Test func excludesCompletionEntriesThemselves() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { completedEntry("L1", op: "OP-A", at: 1) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.isEmpty)
    }

    /// Another directive's unmatched dispatch is not ours to close.
    @Test func excludesOtherDirectivesDispatches() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "theirs", step: nil, operationID: "OP-THEIRS", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L2", op: "OP-OURS", at: 2) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.map(\.id) == ["L2"])
    }

    /// A dispatch naming no operation cannot be matched or closed.
    @Test func excludesDispatchesNamingNoOperation() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
                    summary: "no op", step: nil, operationID: nil, eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.isEmpty)
    }

    /// A third kind naming an operation is neither a dispatch nor a
    /// completion — the `kind` filter must keep it out of `auditLog` on its
    /// own, since an `.opCompleted` row would trivially match its own id.
    @Test func excludesEntriesOfAThirdKindNamingAnOperation() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .resolved,
                    summary: "resolved", step: nil, operationID: "OP-X", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.isEmpty)
    }
}

@Suite struct DispatchedOperationsNarrowing {
    private func operation(_ id: String, kind: OperationKind, status: OperationStatus) -> Operation {
        Operation(
            id: id, entityCode: "V1", kind: kind.rawValue, status: status,
            source: OperationSource.optimistic,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:]),
            directiveID: "D1"
        )
    }

    /// The kinds every mission consumer actually filters for survive; the rest
    /// are dead weight that grows for the life of the directive.
    @Test func keepsPrintAndTravelAndDropsOtherKinds() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-P", kind: .print, status: .completed) }.execute(db)
            try Operation.insert { operation("OP-T", kind: .travel, status: .completed) }.execute(db)
            try Operation.insert { operation("OP-L", kind: OperationKind(rawValue: "launch"), status: .completed) }.execute(db)
            try Operation.insert { operation("OP-R", kind: OperationKind(rawValue: "recall"), status: .completed) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations.keys.sorted() == ["OP-P", "OP-T"])
    }

    /// A print keeps every status, `.superseded` included — `printDiagnosis`
    /// and `printedRelayCode` both need it. The kind filter must never
    /// become a status filter.
    @Test func keepsPrintsOfEveryStatus() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-DONE", kind: .print, status: .completed) }.execute(db)
            try Operation.insert { operation("OP-OPEN", kind: .print, status: .active) }.execute(db)
            try Operation.insert { operation("OP-SUP", kind: .print, status: .superseded) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations.keys.sorted() == ["OP-DONE", "OP-OPEN", "OP-SUP"])
    }

    /// The whole reason the two sets stay separate: a terminal `launch` is
    /// dropped by the kind filter, but the audit pass still has to close it, so
    /// the ops named by an unmatched dispatch come back regardless of kind.
    @Test func keepsAnyKindNamedByAnUnmatchedDispatch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-L", kind: OperationKind(rawValue: "launch"), status: .completed) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-L", at: 1) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations["OP-L"] != nil)
    }

    /// …and once it is closed, it stops coming back.
    @Test func dropsAnAuditedKindOnceItsCompletionIsLogged() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-L", kind: OperationKind(rawValue: "launch"), status: .completed) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-L", at: 1) }.execute(db)
            try DirectiveLogEntry.insert { completedEntry("L2", op: "OP-L", at: 2) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations["OP-L"] == nil)
    }
}

@Suite struct DirectiveSliceComposition {
    /// `WorldSnapshot.read` composes from the same `WorldCore.read` +
    /// `DirectiveSlice.read` this test calls, so `composed == direct` is a
    /// WIRING check only; the five `!isEmpty` assertions carry the weight.
    @Test func composesTheSameSnapshotAsTheDirectRead() async throws {
        let database = try GameDatabase.bootstrap()
        let directive = sliceDirective()
        try await database.write { db in
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-A", at: 1) }.execute(db)
            try Operation.insert {
                Operation(
                    id: "OP-A", entityCode: "V1", kind: OperationKind.print.rawValue,
                    status: .active, source: .optimistic,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:]),
                    directiveID: "D1"
                )
            }.execute(db)
            try seedSystemDetail(db, system: "SOL", scanned: true)
            try seedSalvageAssay(db, id: "SITE-SOL", system: "SOL", totals: ["metal": 100])
        }
        let now = Date(timeIntervalSince1970: 100)

        let composed = try await database.read { db -> WorldSnapshot in
            let core = try WorldCore.read(from: db)
            let slice = try DirectiveSlice.read(from: db, core: core, directive: directive)
            return WorldSnapshot(core: core, slice: slice, now: now)
        }
        let direct = try await WorldSnapshot.read(from: database, now: now, directive: directive)

        #expect(composed == direct)
        #expect(!composed.log.isEmpty)
        #expect(!composed.auditLog.isEmpty)
        #expect(!composed.dispatchedOperations.isEmpty)
        #expect(!composed.systems.isEmpty)
        #expect(!composed.siteAssays.isEmpty)
    }
}

@Suite struct DirectiveSliceBatching {
    /// A directive's slice must not depend on who else was in the batch:
    /// `readAll([a,b])["D1"]` must equal `readAll([a])["D1"]` via `.read`.
    @Test func batchedMatchesIndividualForEachDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let a = directiveFixture(id: "D1", deviceCode: "V1", targets: ["SOL"])
        let b = directiveFixture(id: "D2", deviceCode: "V2", targets: ["VEGA"])
        try await database.write { db in
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-A", at: 1) }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L2", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "theirs", step: nil, operationID: "OP-B", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 2)
                )
            }.execute(db)
        }

        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let batched = try DirectiveSlice.readAll(from: db, core: core, directives: [a, b])
            #expect(batched["D1"] == (try DirectiveSlice.read(from: db, core: core, directive: a)))
            #expect(batched["D2"] == (try DirectiveSlice.read(from: db, core: core, directive: b)))
        }
    }

    /// An empty directive list must not emit `IN ()` or read anything.
    @Test func readsNothingForNoDirectives() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            #expect(try DirectiveSlice.readAll(from: db, core: core, directives: []).isEmpty)
        }
    }
}

@Suite struct DirectiveSliceBatchIsolation {
    private func operation(
        _ id: String, kind: OperationKind, status: OperationStatus = .completed, directiveID: String? = nil
    ) -> Operation {
        Operation(
            id: id, entityCode: "V1", kind: kind.rawValue, status: status,
            source: OperationSource.optimistic,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:]),
            directiveID: directiveID
        )
    }

    /// The naive bug this task exists to catch: a batched query answering
    /// with a missing key, or with a SIBLING directive's rows, for a
    /// directive owning none of its own.
    @Test func logIsScopedPerDirectiveNotUnionedOrMissing() async throws {
        let database = try GameDatabase.bootstrap()
        let a = directiveFixture(id: "D1", deviceCode: "V1")
        let b = directiveFixture(id: "D2", deviceCode: "V2")
        let c = directiveFixture(id: "D3", deviceCode: "V3")
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LA", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                    summary: "a", step: nil, operationID: nil, eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LB", directiveID: "D2", deviceCode: nil, kind: .stepStarted,
                    summary: "b", step: nil, operationID: nil, eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
        }
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let batched = try DirectiveSlice.readAll(from: db, core: core, directives: [a, b, c])
            #expect(batched["D1"]?.log.map(\.id) == ["LA"])
            #expect(batched["D2"]?.log.map(\.id) == ["LB"])
            #expect(batched["D3"] == .empty)
        }
    }

    /// The per-directive bound survives batching: a directive over
    /// `logWindow` is truncated to its OWN newest entries, and a sibling
    /// with only a few entries never borrows from that directive's budget.
    @Test func logWindowIsBoundedPerDirectiveNotAcrossTheBatch() async throws {
        let database = try GameDatabase.bootstrap()
        let big = directiveFixture(id: "D1", deviceCode: "V1")
        let small = directiveFixture(id: "D2", deviceCode: "V2")
        let total = WorldSnapshot.logWindow + 1
        try await database.write { db in
            for index in 0..<total {
                try DirectiveLogEntry.insert {
                    DirectiveLogEntry(
                        id: "BIG-\(index)", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                        summary: "big \(index)", step: nil, operationID: nil, eventID: nil,
                        occurredAt: Date(timeIntervalSince1970: Double(index))
                    )
                }.execute(db)
            }
            for index in 0..<3 {
                try DirectiveLogEntry.insert {
                    DirectiveLogEntry(
                        id: "SMALL-\(index)", directiveID: "D2", deviceCode: nil, kind: .stepStarted,
                        summary: "small \(index)", step: nil, operationID: nil, eventID: nil,
                        occurredAt: Date(timeIntervalSince1970: Double(index))
                    )
                }.execute(db)
            }
        }
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let batched = try DirectiveSlice.readAll(from: db, core: core, directives: [big, small])
            #expect(batched["D1"]?.log.count == WorldSnapshot.logWindow)
            #expect(batched["D1"]?.log.first?.id == "BIG-1")
            #expect(batched["D2"]?.log.map(\.id) == ["SMALL-0", "SMALL-1", "SMALL-2"])
        }
    }

    /// Each directive's unmatched-dispatch worklist is its own, never a
    /// peer's, even though the batched anti-join runs as one query.
    @Test func auditLogIsScopedPerDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let a = directiveFixture(id: "D1", deviceCode: "V1")
        let b = directiveFixture(id: "D2", deviceCode: "V2")
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LA", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
                    summary: "a", step: nil, operationID: "OP-A", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LB", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "b", step: nil, operationID: "OP-B", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
        }
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let batched = try DirectiveSlice.readAll(from: db, core: core, directives: [a, b])
            #expect(batched["D1"]?.auditLog.map(\.id) == ["LA"])
            #expect(batched["D2"]?.auditLog.map(\.id) == ["LB"])
        }
    }

    /// The anti-join is per directive, never scoped to the batch: a
    /// completion logged by D2 for an id D1 ALSO named must not close D1's
    /// own unmatched dispatch of that same id.
    @Test func aSiblingsCompletionOfTheSameOperationIDNeverClosesMyDispatch() async throws {
        let database = try GameDatabase.bootstrap()
        let a = directiveFixture(id: "D1", deviceCode: "V1")
        let b = directiveFixture(id: "D2", deviceCode: "V2")
        try await database.write { db in
            try DirectiveLogEntry.insert { dispatchEntry("LA", op: "OP-SHARED", at: 1) }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LB", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "b", step: nil, operationID: "OP-SHARED", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LC", directiveID: "D2", deviceCode: nil, kind: .opCompleted,
                    summary: "b done", step: nil, operationID: "OP-SHARED", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 2)
                )
            }.execute(db)
        }
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let batched = try DirectiveSlice.readAll(from: db, core: core, directives: [a, b])
            #expect(batched["D1"]?.auditLog.map(\.id) == ["LA"])
            #expect(batched["D2"]?.auditLog.isEmpty == true)
        }
    }

    /// The subtle split: mission half by owner column OR this directive's
    /// own dispatch log; kind-agnostic audit half by this directive's own
    /// auditLog. Getting either wrong hands one directive another's ops.
    @Test func dispatchedOperationsIsScopedPerDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let a = directiveFixture(id: "D1", deviceCode: "V1")
        let b = directiveFixture(id: "D2", deviceCode: "V2")
        try await database.write { db in
            // Mission half, owner column: each directive's own printed op.
            try Operation.insert { operation("OP-A1", kind: .print, directiveID: "D1") }.execute(db)
            try Operation.insert { operation("OP-B1", kind: .print, directiveID: "D2") }.execute(db)
            // Mission half, log fallback: no owner column, named only by
            // that directive's own dispatch entry.
            try Operation.insert { operation("OP-A2", kind: .travel) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("LA2", op: "OP-A2", at: 1) }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LB2", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "b2", step: nil, operationID: "OP-B2", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try Operation.insert { operation("OP-B2", kind: .travel) }.execute(db)
            // Audit half, kind-agnostic: an unmatched dispatch of a kind the
            // mission half would drop, one per directive.
            try Operation.insert { operation("OP-A3", kind: OperationKind(rawValue: "launch")) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("LA3", op: "OP-A3", at: 2) }.execute(db)
            try Operation.insert { operation("OP-B3", kind: OperationKind(rawValue: "recall")) }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "LB3", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "b3", step: nil, operationID: "OP-B3", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 2)
                )
            }.execute(db)
        }
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let batched = try DirectiveSlice.readAll(from: db, core: core, directives: [a, b])
            #expect(batched["D1"]?.dispatchedOperations.keys.sorted() == ["OP-A1", "OP-A2", "OP-A3"])
            #expect(batched["D2"]?.dispatchedOperations.keys.sorted() == ["OP-B1", "OP-B2", "OP-B3"])
        }
    }

    /// A blob decoded for one directive's target must not appear on a
    /// directive whose own `decoded`/`wanted` sets never named it, even
    /// though the two fetches run once across the whole batch.
    @Test func systemsAndSiteAssaysAreScopedPerDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let a = directiveFixture(id: "D1", deviceCode: "V1", targets: ["SOL"])
        let b = directiveFixture(id: "D2", deviceCode: "V2", targets: ["VEGA"])
        try await database.write { db in
            try seedSystemDetail(db, system: "SOL", scanned: true)
            try seedSystemDetail(db, system: "VEGA", scanned: true)
            try seedSalvageAssay(db, id: "SITE-SOL", system: "SOL", totals: ["metal": 10])
            try seedSalvageAssay(db, id: "SITE-VEGA", system: "VEGA", totals: ["metal": 20])
        }
        try await database.read { db in
            let core = try WorldCore.read(from: db)
            let batched = try DirectiveSlice.readAll(from: db, core: core, directives: [a, b])
            #expect(batched["D1"]?.systems.keys.sorted() == ["SOL"])
            #expect(batched["D2"]?.systems.keys.sorted() == ["VEGA"])
            #expect(batched["D1"]?.siteAssays.keys.sorted() == ["SITE-SOL"])
            #expect(batched["D2"]?.siteAssays.keys.sorted() == ["SITE-VEGA"])
        }
    }
}
