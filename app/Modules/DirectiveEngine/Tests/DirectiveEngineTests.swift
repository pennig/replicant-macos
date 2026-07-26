//
//  DirectiveEngineTests.swift
//  Replicould — DirectiveEngine
//
//  The executor loop, driven by fake step machines. No real mission ships until
//  Stage 4, so these tests ARE the proof the loop is correct: one action per
//  evaluation, the right row writes for each, and a timeline entry to match.
//

import ConcurrencyExtras
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

/// A machine that returns a scripted sequence, one action per evaluation, then
/// waits forever.
private struct ScriptedMachine: MissionStepMachine {
    let kind: DirectiveKind
    let firstStep = "start"
    let script: LockIsolated<[MissionAction]>

    init(kind: DirectiveKind = .surveyRun, _ actions: [MissionAction]) {
        self.kind = kind
        script = LockIsolated(actions)
    }

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        script.withValue { remaining in
            remaining.isEmpty ? .wait : remaining.removeFirst()
        }
    }
}

private func mission(
    step: String,
    kind: DirectiveKind = .surveyRun,
    status: DirectiveStatus = .running,
    targets: [String] = ["SOL"],
    targetIndex: Int = 0
) -> Directive {
    Directive(
        id: "D1", kind: kind, status: status, deviceCode: "VES1",
        targets: targets, targetIndex: targetIndex, step: step,
        stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("DirectiveEngine executor")
struct DirectiveEngineTests {
    /// A `.dispatch` action POSTs through the governor, advances the step, and
    /// writes both timeline entries.
    @Test func dispatchAdvancesTheStepAndLogsIt() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .dispatch(kind: .travel, deviceCode: "VES1",
                          params: CommandParams(destination: "SOL"), nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in .dispatched(.accepted(operationID: "OP1")) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")

            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "travelling")
            #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 1_000))
            #expect(directive?.status == .running)

            let entries = try await database.read { db in
                try DirectiveLogEntry.order { $0.id }.fetchAll(db)
            }
            #expect(entries.map(\.kind) == [.stepStarted, .commandDispatched])
            #expect(entries.allSatisfy { $0.directiveID == "D1" })
            #expect(entries.last?.operationID == "OP1")
        }
    }

    /// A DEFERRED dispatch changes nothing: the step doesn't move, nothing is
    /// logged, and the next tick simply asks again. A deferral is not a failure.
    @Test func deferredDispatchLeavesTheDirectiveUntouched() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .dispatch(kind: .travel, deviceCode: "VES1",
                          params: CommandParams(), nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in .deferred(.budgetExhausted) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "start")
            #expect(directive?.status == .running)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    /// A REJECTED command stalls the mission with `commandRejected` — the
    /// engine never improvises or retries at the mission layer.
    @Test func rejectedCommandStallsTheMission() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .dispatch(kind: .travel, deviceCode: "VES1",
                          params: CommandParams(), nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in .dispatched(.rejected("device busy")) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .commandRejected)
            #expect(directive?.step == "start", "a stall must not advance the step")
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stalled])
            #expect(entries.first?.summary.contains("device busy") == true)
        }
    }

    /// `.stall` sets the typed reason and logs it.
    @Test func stallSetsTheReason() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.stall(.noSurveyDroneAboard)])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .noSurveyDroneAboard)
        }
    }

    /// `.advanceTarget` moves the queue on and resets the step to the machine's
    /// first step.
    @Test func advanceTargetMovesTheQueue() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                mission(step: "surveying", targets: ["SOL", "TAU"], targetIndex: 0)
            }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.advanceTarget])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.targetIndex == 1)
            #expect(directive?.step == "start")
            #expect(directive?.currentTarget == "TAU")
        }
    }

    /// `.done` completes the run and writes the completion entry.
    @Test func doneCompletesTheRun() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "surveying") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.done])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .completed)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.directiveCompleted])
        }
    }

    /// `.wait` writes nothing at all — the common case on a long server-side
    /// step, and one that would flood the timeline if it logged.
    @Test func waitWritesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "surveying") }.execute(db)
        }
        let core = DirectiveEngineCore(machines: [ScriptedMachine([.wait])], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "surveying")
            #expect(directive?.updatedAt == Date(timeIntervalSince1970: 0))
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    /// `.advanceStep` moves the step with no command at all — the machine's way
    /// of saying "this step's work was already done".
    @Test func advanceStepMovesWithoutDispatching() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "preflight") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.advanceStep(nextStep: "travelling")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in
                Issue.record("advanceStep must not POST")
                return .deferred(.budgetExhausted)
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "travelling")
            #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 1_000))
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
        }
    }

    /// `.assignController` records the controller — this is what badges and
    /// locks its built-in row for the life of the run.
    @Test func assignControllerRecordsTheController() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "preflight") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.assignController(deviceCode: "AMI1", nextStep: "travelling")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.controllerCode == "AMI1")
            #expect(directive?.step == "travelling")
        }
    }

    /// `.refreshSystem` performs the read, then advances.
    @Test func refreshSystemReadsThenAdvances() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "awaiting") }.execute(db)
        }
        let asked = LockIsolated<String?>(nil)
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshSystem(designation: "SOL", nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.system = { designation in
                asked.setValue(designation)
                return StarSystem(designation: designation, planetsScanned: 2, planetsTotal: 2)
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            #expect(asked.value == "SOL")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
            let stored = try await database.read { db in
                try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
            }
            #expect(try stored?.system().planetsScanned == 2, "the fresh counts must be persisted")
        }
    }

    /// A refresh that 403s (vessel not in that system) still advances — the read
    /// is best-effort, and stalling on it would strand a mission that is fine.
    @Test func refreshSystemAdvancesEvenWhenTheReadFails() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "awaiting") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshSystem(designation: "SOL", nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.system = { _ in throw LocationsError.noReplicantInSystem }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
        }
    }

    /// A directive whose kind has no registered machine is left completely
    /// alone — in this stage that is EVERY production directive, so a bug here
    /// would corrupt rows the moment the engine starts.
    @Test func unknownKindIsLeftAlone() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start", kind: .relayRun) }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine(kind: .surveyRun, [.done])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .running)
            #expect(directive?.step == "start")
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    /// A stalled, paused, or finished directive is not evaluated — resolution
    /// is the user's move, and a tick must never resume one behind their back.
    @Test func nonRunningDirectivesAreNotEvaluated() async throws {
        for status in [DirectiveStatus.needsAttention, .paused, .completed, .cancelled] {
            let database = try GameDatabase.bootstrap()
            try await database.write { db in
                try Directive.insert { mission(step: "start", status: status) }.execute(db)
            }
            let core = DirectiveEngineCore(machines: [ScriptedMachine([.done])], tick: .seconds(5))
            try await withDependencies {
                $0.defaultDatabase = database
                $0.date = .constant(Date(timeIntervalSince1970: 1_000))
                $0.uuid = .incrementing
            } operation: {
                await core.evaluateOnce(directiveID: "D1")
                let directive = try await database.read { db in
                    try Directive.where { $0.id.eq("D1") }.fetchOne(db)
                }
                #expect(directive?.status == status, "\(status) must not be advanced by a tick")
                #expect(directive?.step == "start")
            }
        }
    }

    /// The supervisor spawns exactly one executor per running directive, and
    /// none for the rest.
    @Test func supervisorSpawnsOneExecutorPerRunningDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let stalled: Directive = {
            var directive = mission(step: "start", status: .needsAttention)
            directive.id = "D2"
            return directive
        }()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
            try Directive.insert { stalled }.execute(db)
        }
        let core = DirectiveEngineCore(machines: [ScriptedMachine([.wait])], tick: .seconds(5))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
        } operation: {
            // `start()` first: reconciliation is deliberately inert on a
            // stopped engine, so a teardown mid-read can't resurrect executors.
            await core.start()
            await core.reconcileExecutors()
            let count = await core.executorCount
            #expect(count == 1, "only the running directive gets an executor")
            await core.stop()
        }
    }

    /// `stop()` cancels the supervisor and every executor — a logout must not
    /// leave a task writing into freshly-wiped tables.
    @Test func stopCancelsEverything() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(machines: [ScriptedMachine([.wait])], tick: .seconds(5))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
        } operation: {
            await core.start()
            await core.reconcileExecutors()
            #expect(await core.executorCount == 1)
            await core.stop()
            #expect(await core.executorCount == 0)
        }
    }
}

// MARK: - Staging freshness (.refreshDevices)

/// A device carrying a `stowed_devices` manifest, as the single-device read
/// returns it — the list the engine expands a carrier refresh into.
private func carrier(_ code: String, stowing: [String] = []) -> Device {
    var detail: [String: JSONValue] = [:]
    if !stowing.isEmpty {
        detail["stowed_devices"] = .array(stowing.map { .object(["device_code": .string($0)]) })
    }
    return Device(
        deviceCode: code, deviceType: "transport_hauler", replicantCode: "R1", status: "idle",
        location: "SOL-3", locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
        detail: .object(detail), updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// `.refreshDevices` is the mission's way of saying "read this before I believe
/// it" — the answer to a stalled Survey Run that was judging staging from rows
/// the read budget had kept it from refreshing.
@Suite("DirectiveEngine — staging freshness")
struct DirectiveRefreshDevicesTests {
    /// Fresh reads that repair the rows let the run continue: the machine's
    /// second answer is the one applied, and no stall is ever written.
    @Test func refreshedRowsLetTheRunProceed() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let reads = LockIsolated<[(String, RefreshPriority)]>([])
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyControllerAboard),
                .advanceStep(nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, priority in
                reads.withValue { $0.append((code, priority)) }
                return carrier(code)
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .running)
            #expect(directive?.step == "travelling")
            #expect(directive?.attentionReason == nil)
        }
        #expect(reads.value.map(\.0) == ["VES1"])
        // `.high`, so neither the TTL nor the read-budget floor can defer the
        // one read standing between the run and a dead stop.
        #expect(reads.value.allSatisfy { $0.1 == .high })
    }

    /// A carrier refresh expands into its stowed children: the staging checks
    /// read each CHILD's stow column, so refreshing the vessel alone would leave
    /// the rows the answer depends on exactly as stale as they were.
    @Test func aCarrierRefreshExpandsToItsStowedDevices() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let reads = LockIsolated<[String]>([])
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyControllerAboard),
                .advanceStep(nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                reads.withValue { $0.append(code) }
                return code == "VES1" ? carrier(code, stowing: ["AMI1", "DRONE1"]) : carrier(code)
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
        }
        #expect(reads.value.sorted() == ["AMI1", "DRONE1", "VES1"])
    }

    /// Asked twice with an authoritative read in between and still unstaged: the
    /// staging really is missing, so the carried reason surfaces. This is the
    /// loop guard — exactly ONE refresh round per evaluation, no matter how
    /// insistent the machine is.
    @Test func aConfirmedFindingStallsWithTheCarriedReason() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let reads = LockIsolated<[String]>([])
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyControllerAboard),
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyControllerAboard),
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyControllerAboard),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                reads.withValue { $0.append(code) }
                return carrier(code)
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .noSurveyControllerAboard)
        }
        #expect(reads.value == ["VES1"], "one refresh round per evaluation, never a loop")
    }

    /// A read that fails outright still surfaces the finding rather than
    /// spinning: the run stops with the reason the user can act on.
    @Test func failedReadsStillSurfaceTheFinding() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyDroneAboard),
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyDroneAboard),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { _, _ in nil }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .noSurveyDroneAboard)
        }
    }
}
