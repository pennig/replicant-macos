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
    /// completion — the `kind` filter, not just the anti-join, must keep it
    /// out. An `.opCompleted` row would be excluded by the anti-join alone
    /// (it always matches its own operation id), so only a kind that is
    /// NEITHER `.commandDispatched` NOR `.opCompleted` can prove this clause.
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
