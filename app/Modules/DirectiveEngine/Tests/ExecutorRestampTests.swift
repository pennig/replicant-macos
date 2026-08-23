//
//  ExecutorRestampTests.swift
//  Replicould — DirectiveEngine
//
//  A read into the step it is already on must not restart that step's
//  deadline: `move`'s `restamp` parameter and the log entry it gates.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameSession
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine
@testable import GameServices

/// A machine that returns a scripted sequence, one action per evaluation, then
/// waits forever — duplicated locally so this file has no dependency on
/// another test file's private `ScriptedMachine`.
private struct ScriptedMachine: MissionStepMachine {
    let kind: DirectiveKind = .surveyRun
    let firstStep = "start"
    let script: LockIsolated<[MissionAction]>

    init(_ actions: [MissionAction]) {
        script = LockIsolated(actions)
    }

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        script.withValue { remaining in
            remaining.isEmpty ? .wait : remaining.removeFirst()
        }
    }

    func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}

private let t0 = Date(timeIntervalSince1970: 1_000)
private let t1 = Date(timeIntervalSince1970: 1_030)

private func mission(step: String) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        targets: ["SOL"], targetIndex: 0, step: step,
        stepStartedAt: t0, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: t0, updatedAt: t0
    )
}

@Suite("DirectiveExecutor restamp")
struct ExecutorRestampTests {
    /// A read whose `nextStep` is the step it is already on must not restart
    /// the deadline, and must leave the timeline silent — exactly `.wait`.
    @Test func refreshSystemIntoSameStepKeepsTheClock() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "confirming") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshSystem(designation: "TAU", nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
            #expect(directive?.stepStartedAt == t0)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    /// A read that DOES move the step restamps and logs normally.
    @Test func refreshSystemIntoAnotherStepRestamps() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "confirming") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshSystem(designation: "TAU", nextStep: "settling")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "settling")
            #expect(directive?.stepStartedAt == t1)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
        }
    }

    /// `.advanceStep`'s semantics are unchanged: it always re-stamps, even
    /// into its own step.
    @Test func advanceStepAlwaysRestamps() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "confirming") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.advanceStep(nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
            #expect(directive?.stepStartedAt == t1)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
        }
    }

    @Test func scanSystemIntoSameStepKeepsTheClock() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "scanning") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.scanSystem(designation: "TAU", nextStep: "scanning")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "scanning")
            #expect(directive?.stepStartedAt == t0)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    @Test func scanSystemIntoAnotherStepRestamps() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "scanning") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.scanSystem(designation: "TAU", nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
            #expect(directive?.stepStartedAt == t1)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
        }
    }

    @Test func refreshBodyIntoSameStepKeepsTheClock() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "verifying") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshBody(system: "TAU", body: "TAU-3", nextStep: "verifying")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
            $0.locationsClient.body = { _ in throw LocationsError.notFound }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "verifying")
            #expect(directive?.stepStartedAt == t0)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    @Test func refreshBodyIntoAnotherStepRestamps() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "verifying") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshBody(system: "TAU", body: "TAU-3", nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
            $0.locationsClient.body = { _ in throw LocationsError.notFound }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
            #expect(directive?.stepStartedAt == t1)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
        }
    }

    @Test func setDeviceTagsIntoSameStepKeepsTheClock() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "configuring") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .setDeviceTags(deviceCode: "RELAY", tags: ["operator:keep"], nextStep: "configuring"),
            ])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
            $0.devicesClient.updateTags = { _, _ in }
            $0.deviceRefresher.refresh = { _, _ in nil }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "configuring")
            #expect(directive?.stepStartedAt == t0)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    @Test func setDeviceTagsIntoAnotherStepRestamps() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "confirmingRelay") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .setDeviceTags(deviceCode: "RELAY", tags: ["operator:keep"], nextStep: "configuring"),
            ])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
            $0.devicesClient.updateTags = { _, _ in }
            $0.deviceRefresher.refresh = { _, _ in nil }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "configuring")
            #expect(directive?.stepStartedAt == t1)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
        }
    }

    /// The payload lease survives a step move it has nothing to do with. Proves
    /// the migration and the round trip; what proves `commit`'s column list is
    /// `releasePayloadClearsTheColumnAndAdvancesTheStep`, which changes it.
    @Test func aPayloadLeaseSurvivesAnUnrelatedStepMove() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            var row = mission(step: "confirming")
            row.payloadCode = "PAYLOAD1"
            try Directive.insert { row }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.advanceStep(nextStep: "settling")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.payloadCode == "PAYLOAD1")
            #expect(directive?.step == "settling")
        }
    }

    /// The clear has to survive `commit`, which names its columns explicitly —
    /// a `payloadCode` missing from that list discards this write with no error.
    @Test func releasePayloadClearsTheColumnAndAdvancesTheStep() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            var row = mission(step: "confirmingDetach")
            row.payloadCode = "PAYLOAD1"
            try Directive.insert { row }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.releasePayload(nextStep: "homing")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t1)
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.payloadCode == nil)
            #expect(directive?.step == "homing")
            #expect(directive?.stepStartedAt == t1)
        }
    }
}
