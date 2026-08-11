//
//  DirectiveRetentionTests.swift
//  Replicould — GameSync
//
//  The unattended purge over `directives`: what it may destroy, and the two
//  things it must never do — touch an open run, or mark one.

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameSync

private let now = Date(timeIntervalSince1970: 10_000_000)

private func directive(
    _ id: String,
    status: DirectiveStatus,
    updatedAt: Date,
    deletedAt: Date? = nil
) -> Directive {
    Directive(
        id: id, kind: .surveyRun, status: status, deviceCode: "DEV-\(id)",
        targets: [], targetIndex: 0, step: "preflight", stepStartedAt: updatedAt,
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        deletedAt: deletedAt, createdAt: updatedAt, updatedAt: updatedAt
    )
}

private func entry(_ id: String, directiveID: String?, deviceCode: String? = nil) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: directiveID, deviceCode: deviceCode,
        kind: .stepStarted, summary: "step", step: "preflight",
        operationID: nil, eventID: nil, occurredAt: now
    )
}

private func seed(_ directives: [Directive], _ entries: [DirectiveLogEntry] = []) async throws -> any DatabaseWriter {
    let database = try GameDatabase.bootstrap()
    try await database.write { db in
        for d in directives { try Directive.insert { d }.execute(db) }
        for e in entries { try DirectiveLogEntry.insert { e }.execute(db) }
    }
    return database
}

private func rows(_ database: any DatabaseReader) async throws -> [Directive] {
    try await database.read { db in try Directive.all.fetchAll(db) }
}

private func entryIDs(_ database: any DatabaseReader) async throws -> Set<String> {
    try await database.read { db in Set(try DirectiveLogEntry.all.fetchAll(db).map(\.id)) }
}

@Suite("Directive retention")
struct DirectiveRetentionTests {
    /// The hourly sweep is what makes the month a bound rather than a floor:
    /// the Clear button's own purge only runs when someone clicks it.
    @Test func purgesATerminalRunPastTheWindowAndItsTimeline() async throws {
        let stale = now.addingTimeInterval(-Directive.purgeWindow - 60)
        let database = try await seed(
            [directive("OLD", status: .completed, updatedAt: stale, deletedAt: stale)],
            [entry("E-OLD", directiveID: "OLD")]
        )

        let purged = await DirectiveRetention.sweep(database, now: now)

        #expect(purged == 1)
        #expect(try await rows(database).isEmpty)
        #expect(try await entryIDs(database).isEmpty)
    }

    /// An open run still OWNS its devices, and this sweep runs unattended: a
    /// mission whose row vanished mid-flight would strand its whole fleet.
    @Test func neverPurgesAnOpenRunHoweverOld() async throws {
        let ancient = now.addingTimeInterval(-Directive.purgeWindow * 12)
        let database = try await seed(
            DirectiveStatus.openCases.map { directive($0.rawValue, status: $0, updatedAt: ancient) },
            [entry("E-LIVE", directiveID: DirectiveStatus.running.rawValue)]
        )

        let purged = await DirectiveRetention.sweep(database, now: now)

        #expect(purged == 0)
        #expect(try await rows(database).count == DirectiveStatus.openCases.count)
        #expect(try await entryIDs(database) == ["E-LIVE"])
    }

    /// The sweep never marks. Hiding a run from the list is an operator action,
    /// so a finished run inside the window comes through completely untouched.
    @Test func neverMarksAnythingItself() async throws {
        let recent = now.addingTimeInterval(-Directive.purgeWindow + 60)
        let database = try await seed(
            [directive("YOUNG", status: .completed, updatedAt: recent)],
            [entry("E-YOUNG", directiveID: "YOUNG")]
        )

        let purged = await DirectiveRetention.sweep(database, now: now)

        #expect(purged == 0)
        let row = try await rows(database).first
        #expect(row?.deletedAt == nil)
        #expect(row?.updatedAt == recent)
        #expect(try await entryIDs(database) == ["E-YOUNG"])
    }

    /// The purge's entry delete is scoped by directive id. Another run's entry
    /// and a device-scoped one (`directiveID` nil) both survive.
    @Test func onlyTouchesTheDoomedRunsOwnEntries() async throws {
        let stale = now.addingTimeInterval(-Directive.purgeWindow - 60)
        let database = try await seed(
            [
                directive("OLD", status: .cancelled, updatedAt: stale),
                directive("LIVE", status: .running, updatedAt: stale),
            ],
            [
                entry("E-OLD", directiveID: "OLD"),
                entry("E-LIVE", directiveID: "LIVE"),
                entry("E-DEVICE", directiveID: nil, deviceCode: "CTRL1"),
            ]
        )

        #expect(await DirectiveRetention.sweep(database, now: now) == 1)
        #expect(try await entryIDs(database) == ["E-LIVE", "E-DEVICE"])
    }
}
