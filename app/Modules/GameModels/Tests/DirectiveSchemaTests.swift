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
    /// A custom mission round-trips every column, including the JSON target queue.
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
    }

    /// A log entry attaches to a custom directive OR to a device (a built-in
    /// AMI directive) — the optional pair is what lets one table serve both
    /// row kinds in the Directives list.
    @Test func logEntryAttachesToEitherKind() throws {
        let database = try GameDatabase.bootstrap()
        let custom = DirectiveLogEntry(
            id: "L1", directiveID: "D1", deviceCode: nil,
            kind: .stepStarted, summary: "Travelling to TAU",
            operationID: "OP1", eventID: nil,
            occurredAt: Date(timeIntervalSince1970: 10)
        )
        let builtIn = DirectiveLogEntry(
            id: "L2", directiveID: nil, deviceCode: "AMI1",
            kind: .directiveCompleted, summary: "survey_system completed",
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
        #expect(loaded.last?.directiveID == nil)
    }
}
