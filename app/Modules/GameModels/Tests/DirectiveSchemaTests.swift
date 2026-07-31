//
//  DirectiveSchemaTests.swift
//  Replicould — GameModels
//
//  The Directive / DirectiveLogEntry tables round-trip through the composed
//  schema. Both are account-scoped and wiped on logout; these tests pin the
//  columns the engine (Stage 3+) and the Directives list depend on.
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
@testable import GameModels

@Suite("Directive schema")
struct DirectiveSchemaTests {
    /// A custom mission round-trips every column, including the JSON target
    /// queue, `stepStartedAt`, and a typed `attentionReason`.
    @Test func directiveRoundTrips() throws {
        let database = try GameDatabase.bootstrap()
        let directive = Directive(
            id: "D1",
            kind: .surveyRun,
            status: .running,
            deviceCode: "VESSEL1",
            targets: ["TAU", "SHERATANON"],
            targetIndex: 1,
            step: "surveying",
            stepStartedAt: Date(timeIntervalSince1970: 150),
            returnToOrigin: true,
            originDesignation: "SOL",
            attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try database.write { db in try Directive.insert { directive }.execute(db) }

        let loaded = try database.read { db in try Directive.all.fetchAll(db) }
        #expect(loaded == [directive])
        #expect(loaded.first?.targets == ["TAU", "SHERATANON"])
        #expect(loaded.first?.kind == .surveyRun)
        #expect(loaded.first?.returnToOrigin == true)
        #expect(loaded.first?.stepStartedAt == Date(timeIntervalSince1970: 150))
    }

    /// Every stall reason reads as a sentence, not a case name — the detail
    /// pane shows these directly to the user, who is being asked to fix
    /// something and needs to know what.
    @Test func everyAttentionReasonHasWords() {
        for reason in DirectiveAttentionReason.allCases {
            #expect(reason.displayName != reason.rawValue)
            #expect(!reason.displayName.isEmpty)
            #expect(!reason.guidance.isEmpty)
        }
    }

    /// `controllerCode` round-trips, and defaults to nil for a mission that
    /// hasn't reached its `set_directive` step yet. It is what makes an
    /// engine-driven built-in row knowable: the vessel (`deviceCode`) can never
    /// stand in for it, since a Survey Run's vessel and its AMI controller are
    /// two different devices.
    @Test func controllerCodeRoundTrips() throws {
        let database = try GameDatabase.bootstrap()
        let unassigned = Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VESSEL1",
            targets: ["SOL"], targetIndex: 0, step: "stow",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        let driving = Directive(
            id: "D2", kind: .surveyRun, status: .running, deviceCode: "VESSEL2",
            controllerCode: "AMI1",
            targets: ["SOL"], targetIndex: 0, step: "surveying",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        try database.write { db in
            try Directive.insert { unassigned }.execute(db)
            try Directive.insert { driving }.execute(db)
        }

        let loaded = try database.read { db in try Directive.order { $0.id }.fetchAll(db) }
        #expect(loaded.map(\.controllerCode) == [nil, "AMI1"])
        #expect(loaded == [unassigned, driving])
    }

    /// A typed `attentionReason` round-trips too — the stalled-directive path,
    /// distinct from the happy-path row above.
    @Test func attentionReasonRoundTrips() throws {
        let database = try GameDatabase.bootstrap()
        let directive = Directive(
            id: "D2",
            kind: .relayRun,
            status: .needsAttention,
            deviceCode: "VESSEL2",
            targets: ["TAU"],
            targetIndex: 0,
            step: "relaying",
            stepStartedAt: Date(timeIntervalSince1970: 300),
            returnToOrigin: false,
            originDesignation: nil,
            attentionReason: .noRelayCoLocated,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try database.write { db in try Directive.insert { directive }.execute(db) }

        let loaded = try database.read { db in try Directive.all.fetchAll(db) }
        #expect(loaded.first?.attentionReason == .noRelayCoLocated)
    }

    /// A log entry attaches to a custom directive OR to a device (a built-in
    /// AMI directive) — the optional pair is what lets one table serve both
    /// row kinds in the Directives list. `step` round-trips too, so a
    /// `.stepStarted` entry can be attributed without string-matching `summary`.
    @Test func logEntryAttachesToEitherKind() throws {
        let database = try GameDatabase.bootstrap()
        let custom = DirectiveLogEntry(
            id: "L1", directiveID: "D1", deviceCode: nil,
            kind: .stepStarted, summary: "Travelling to TAU", step: "travelling",
            operationID: "OP1", eventID: nil,
            occurredAt: Date(timeIntervalSince1970: 10)
        )
        let builtIn = DirectiveLogEntry(
            id: "L2", directiveID: nil, deviceCode: "AMI1",
            kind: .directiveCompleted, summary: "survey_system completed", step: nil,
            operationID: nil, eventID: "E9",
            occurredAt: Date(timeIntervalSince1970: 20)
        )
        try database.write { db in
            try DirectiveLogEntry.insert { custom }.execute(db)
            try DirectiveLogEntry.insert { builtIn }.execute(db)
        }

        let loaded = try database.read { db in
            try DirectiveLogEntry.order { $0.occurredAt }.fetchAll(db)
        }
        #expect(loaded == [custom, builtIn])
        #expect(loaded.first?.deviceCode == nil)
        #expect(loaded.first?.step == "travelling")
        #expect(loaded.last?.directiveID == nil)
        #expect(loaded.last?.step == nil)
    }

    /// The partial unique index rejects a second entry with the same non-nil
    /// `eventID` (a replayed or catch-up-redelivered SSE event would otherwise
    /// duplicate the timeline row), while entries with no event at all
    /// (`eventID == nil`) are unconstrained — there can be many.
    @Test func eventIDUniquenessIsPartial() throws {
        let database = try GameDatabase.bootstrap()
        let first = DirectiveLogEntry(
            id: "L1", directiveID: "D1", deviceCode: nil,
            kind: .stepStarted, summary: "first", step: nil,
            operationID: nil, eventID: "E1",
            occurredAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = DirectiveLogEntry(
            id: "L2", directiveID: "D1", deviceCode: nil,
            kind: .stepStarted, summary: "replayed", step: nil,
            operationID: nil, eventID: "E1",
            occurredAt: Date(timeIntervalSince1970: 11)
        )
        try database.write { db in try DirectiveLogEntry.insert { first }.execute(db) }
        #expect(throws: (any Error).self) {
            try database.write { db in try DirectiveLogEntry.insert { duplicate }.execute(db) }
        }

        // Multiple nil-eventID entries are unaffected by the partial index.
        let nilA = DirectiveLogEntry(
            id: "L3", directiveID: "D1", deviceCode: nil,
            kind: .stepStarted, summary: "no event a", step: nil,
            operationID: nil, eventID: nil,
            occurredAt: Date(timeIntervalSince1970: 12)
        )
        let nilB = DirectiveLogEntry(
            id: "L4", directiveID: "D1", deviceCode: nil,
            kind: .stepStarted, summary: "no event b", step: nil,
            operationID: nil, eventID: nil,
            occurredAt: Date(timeIntervalSince1970: 13)
        )
        try database.write { db in
            try DirectiveLogEntry.insert { nilA }.execute(db)
            try DirectiveLogEntry.insert { nilB }.execute(db)
        }

        let loaded = try database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(loaded.count == 3)
    }

    @Test func salvageRunKindHasATitle() {
        #expect(DirectiveKind.salvageRun.title == "Salvage Run")
    }

    @Test func newAttentionReasonsCarryGuidance() {
        // Every stall the engine can produce must name a fix — the panel renders
        // `guidance` verbatim, and an empty one reads as a dead end.
        for reason in [
            DirectiveAttentionReason.noMiningControllerAboard,
            .noMiningDroneAboard,
            .awaitingRelayRestock,
            .relayActivationFailed,
        ] {
            #expect(!reason.displayName.isEmpty)
            #expect(!reason.guidance.isEmpty)
        }
    }

    @Test func fleetTagRoundTripsThroughTheRow() throws {
        let database = try GameDatabase.bootstrap()
        let directive = Directive(
            id: "d1", kind: .salvageRun, status: .running, deviceCode: "VESSEL",
            fleetTag: "auto:salvage", targets: ["TOSLIT"], targetIndex: 0,
            step: "preflight", stepStartedAt: .distantPast, returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        try database.write { try Directive.insert { directive }.execute($0) }
        let read = try database.read { try Directive.all.fetchAll($0) }
        #expect(read.first?.fleetTag == "auto:salvage")
    }
}
