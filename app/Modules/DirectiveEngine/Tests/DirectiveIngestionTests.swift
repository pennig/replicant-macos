//
//  DirectiveIngestionTests.swift
//  Replicould — DirectiveEngine
//
//  The `directive.*` route: one log entry per completion, deduped by event id,
//  attributed to a mission only when the issue-time-relative guard passes.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import DirectiveEngine

private func moment(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func completion(
    id: String,
    device: String,
    at iso: String = "2026-07-25T12:05:00Z",
    name: String = "survey_system"
) -> GameEventEnvelope {
    GameEventEnvelope(
        id: id,
        category: "directive",
        event: "directive.completed",
        deviceCode: device,
        star: "SHERATANON",
        payload: ["directive": .string(name)],
        createdAt: iso
    )
}

private func mission(stepStartedAt: Date, status: DirectiveStatus = .running) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: status, deviceCode: "VES1",
        controllerCode: "AMI1",
        targets: ["SHERATANON"], targetIndex: 0, step: "surveying",
        stepStartedAt: stepStartedAt, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Directive ingestion")
struct DirectiveIngestionTests {
    /// A completion with no owning mission still lands as built-in history,
    /// keyed by the controller.
    @Test func recordsABuiltInCompletion() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(completion(id: "E1", device: "AMI1"))
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.count == 1)
        #expect(entries[0].deviceCode == "AMI1")
        #expect(entries[0].directiveID == nil)
        #expect(entries[0].eventID == "E1")
        #expect(entries[0].kind == .directiveCompleted)
        #expect(entries[0].occurredAt == moment("2026-07-25T12:05:00Z"))
        #expect(entries[0].summary.contains("SHERATANON"))
    }

    /// Re-delivery (catch-up replay, reconnect) must not duplicate the timeline.
    @Test func isIdempotentPerEventID() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(completion(id: "E1", device: "AMI1"))
            await DirectiveIngestion.eventRoute.apply(completion(id: "E1", device: "AMI1"))
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.count == 1)
    }

    /// A live mission driving that controller gets the entry attributed to it,
    /// so the mission timeline shows the completion it was waiting for.
    @Test func attributesToTheOwningMission() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(stepStartedAt: moment("2026-07-25T12:00:00Z")) }.execute(db)
        }
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(completion(id: "E1", device: "AMI1"))
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries[0].directiveID == "D1")
        #expect(entries[0].deviceCode == "AMI1")
        #expect(entries[0].step == "surveying")
    }

    /// A completion stamped BEFORE the current step started belongs to an
    /// earlier action — recorded as history, never attributed. This is the
    /// replay guard from spec §5: issue-time relative, not wall-clock, so a
    /// post-close catch-up completion still lands correctly.
    @Test func doesNotAttributeAReplayedPreStepCompletion() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(stepStartedAt: moment("2026-07-25T12:00:00Z")) }.execute(db)
        }
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(
                completion(id: "E1", device: "AMI1", at: "2026-07-25T11:50:00Z")
            )
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.count == 1)
        #expect(entries[0].directiveID == nil, "a pre-step completion must not close the current step")
        #expect(entries[0].deviceCode == "AMI1")
    }

    /// Within the 5s skew tolerance an event marginally older than the step
    /// start still counts — client and server clocks are not identical.
    @Test func toleratesClockSkew() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(stepStartedAt: moment("2026-07-25T12:00:00Z")) }.execute(db)
        }
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(
                completion(id: "E1", device: "AMI1", at: "2026-07-25T11:59:57Z")
            )
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries[0].directiveID == "D1")
    }

    /// A mission that is no longer running does not claim the completion: the
    /// user may have cancelled it while the controller finished its work.
    @Test func doesNotAttributeToANonRunningMission() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                mission(stepStartedAt: moment("2026-07-25T12:00:00Z"), status: .cancelled)
            }.execute(db)
        }
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(completion(id: "E1", device: "AMI1"))
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries[0].directiveID == nil)
        #expect(entries[0].deviceCode == "AMI1")
    }

    /// An unrecognised `directive.*` name is logged, not written — the route
    /// matches the whole category, so it must not invent completions.
    @Test func ignoresUnknownDirectiveEvents() async throws {
        let database = try GameDatabase.bootstrap()
        let unknown = GameEventEnvelope(
            id: "E2", category: "directive", event: "directive.assigned",
            deviceCode: "AMI1", payload: ["directive": .string("survey_system")],
            createdAt: "2026-07-25T12:05:00Z"
        )
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(unknown)
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.isEmpty)
    }

    /// A completion naming no device can't be attributed to anything, so it is
    /// dropped rather than written with a null key.
    @Test func skipsACompletionWithNoDeviceCode() async throws {
        let database = try GameDatabase.bootstrap()
        let anonymous = GameEventEnvelope(
            id: "E3", category: "directive", event: "directive.completed",
            payload: ["directive": .string("survey_system")],
            createdAt: "2026-07-25T12:05:00Z"
        )
        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(moment("2026-07-25T12:05:00Z"))
        } operation: {
            await DirectiveIngestion.eventRoute.apply(anonymous)
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.isEmpty)
    }
}
