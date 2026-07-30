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
/// Reading a whole system in one request instead of one request per device.
///
/// `GET devices?location=<STAR>` returns every device the server considers
/// PRESENT in that system, in-transit ones included (a travelling device reports
/// `location: null` but is still matched by the filter; probed live 2026-07-27),
/// and the cost does not scale with the size of the fleet.
///
/// Presence is the limit of what it can answer. A STOWED device has no location
/// and is simply absent from the response — six drones stowed aboard a vessel
/// left `location=ESELLUSAU` returning only the vessel (probed live 2026-07-29).
/// The recall gate that once used this action now names its drones instead; these
/// tests cover the resolver's own contract, not that gate.
@Suite("DirectiveEngine — system-scoped refresh")
struct DirectiveRefreshInSystemTests {
    /// One filtered request, and every device it returns is reconciled — so the
    /// machine's second answer is computed against rows that now exist.
    @Test func readsTheSystemOnceAndReconcilesEveryDevice() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let queries = LockIsolated<[String]>([])
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevicesInSystem(designation: "TAU", thenStall: .dronesNotRecovered),
                .advanceStep(nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchAtLocation = { designation in
                queries.withValue { $0.append(designation) }
                return [carrier("VES1"), carrier("AMI1"), carrier("DRONE0")]
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "travelling")
            #expect(directive?.attentionReason == nil)
            let stored = try await database.read { db in
                try Device.all.fetchAll(db).map(\.deviceCode).sorted()
            }
            #expect(stored == ["AMI1", "DRONE0", "VES1"])
        }
        // Exactly one request for the whole system, not one per device.
        #expect(queries.value == ["TAU"])
    }

    /// Still unresolved after an authoritative system read: the carried reason
    /// surfaces. Same one-round loop guard as `.refreshDevices`.
    @Test func stillUnresolvedAfterTheReadSurfacesTheReason() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevicesInSystem(designation: "TAU", thenStall: .dronesNotRecovered),
                .refreshDevicesInSystem(designation: "TAU", thenStall: .dronesNotRecovered),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchAtLocation = { _ in [] }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .dronesNotRecovered)
        }
    }

    /// A nil fallback waits instead of stalling — drones still in flight are the
    /// expected answer, not a fault.
    @Test func aNilFallbackWaitsInsteadOfStalling() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevicesInSystem(designation: "TAU", thenStall: nil),
                .refreshDevicesInSystem(designation: "TAU", thenStall: nil),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchAtLocation = { _ in [] }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .running)
            #expect(directive?.attentionReason == nil)
        }
    }

    /// A failed read must not strand the run: the carried fallback applies, and
    /// nothing is pruned. A filtered walk is NOT the authoritative full fleet,
    /// so treating its absences as "device gone" would delete the fleet.
    @Test func aFailedReadHonoursTheFallbackAndPrunesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
            try Device.insert { carrier("ELSEWHERE") }.execute(db)
        }
        struct ReadFailure: Error {}
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevicesInSystem(designation: "TAU", thenStall: .dronesNotRecovered),
                .refreshDevicesInSystem(designation: "TAU", thenStall: .dronesNotRecovered),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchAtLocation = { _ in throw ReadFailure() }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.attentionReason == .dronesNotRecovered)
            let stored = try await database.read { db in
                try Device.all.fetchAll(db).map(\.deviceCode)
            }
            #expect(stored == ["ELSEWHERE"])
        }
    }
}

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

// MARK: - Continuous roam resolution

/// The engine side of `.extendQueue`: the census read, the append, and the
/// re-ask. Driven through `evaluateOnce` with the REAL `SurveyRun` machine
/// rather than a `ScriptedMachine`, because the property most worth protecting
/// here lives in the hand-off between the resolver and the executor and a
/// scripted machine would not exercise it.
///
/// Most of these deliberately leave the fleet unstaged, so after the append the
/// machine asks for a device refresh; their assertions are about `targets`, never
/// about the step reached. That an unstaged fixture ends up stalled is a property
/// of the FIXTURE, not of extending a queue — reading it as "extends stall, of
/// course they do" is what let a real bug hide here, so
/// `aRefreshDemandedAfterTheAppendIsPaidForRatherThanStalled` stages a fleet
/// properly and pins the opposite.
@Suite("DirectiveEngine roam resolution")
struct DirectiveEngineRoamTests {
    /// A census row `x` light-years out along the X axis.
    private func star(_ designation: String, x: Double, scanned: Bool = false) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil,
            fullyScannedAt: scanned ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    /// A roam directive with an exhausted queue, ready to be extended.
    private func roamDirective(targets: [String] = [], targetIndex: Int = 0) -> Directive {
        Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            controllerCode: nil, roamCentre: "CENTRE",
            targets: targets, targetIndex: targetIndex,
            step: SurveyRun().firstStep,
            stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: "CENTRE",
            attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// The run's vessel. It MUST exist: `SurveyRun.nextAction` stalls with
    /// `.unreachableDevice` before preflight runs at all if the directive's
    /// device is missing, so without this row no test here reaches the roam
    /// branch. Deliberately unstaged — no controller, no drones — because these
    /// tests are about the queue, and preflight's staging verdict is
    /// `SurveyRunTests`' business.
    private var vessel: Device {
        Device(
            deviceCode: "VES1", deviceType: "transport_hauler", replicantCode: "R1",
            status: "idle", location: "CENTRE-1", locationName: nil,
            operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// A vessel with a survey controller and one adopted drone stowed aboard, all
    /// stamped `updatedAt` — the staged state a real roam run is in, and the only
    /// state in which preflight gets past its staging checks to the freshness
    /// demand this suite's regression is about.
    private func stagedFleet(updatedAt: Date) -> [Device] {
        func make(
            _ code: String, type: String, stowedIn: String? = nil,
            controlledBy: String? = nil, directives: [String] = []
        ) -> Device {
            var detail: [String: JSONValue] = [:]
            if !directives.isEmpty {
                detail["available_directives"] = .array(directives.map(JSONValue.string))
            }
            return Device(
                deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
                // Stowing CLEARS a device's location, exactly as the server
                // reports it.
                location: stowedIn == nil ? "CENTRE-1" : nil, locationName: nil,
                operationalCapacity: 100, queueSize: 0,
                stowedInDeviceCode: stowedIn, controllerDeviceCode: controlledBy,
                attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
                availableCommands: [], features: [], tags: [], detail: .object(detail),
                updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
            )
        }
        return [
            make("VES1", type: "transport_hauler"),
            make("AMI1", type: "ami_survey_controller", stowedIn: "VES1",
                 directives: ["survey_system"]),
            make("DRONE1", type: "survey_drone", stowedIn: "VES1", controlledBy: "AMI1"),
        ]
    }

    private func seed(
        _ database: any DatabaseWriter, _ directive: Directive, _ stars: [Star],
        devices: [Device]? = nil
    ) async throws {
        let fleet = devices ?? [vessel]
        try await database.write { db in
            for star in stars { try Star.insert { star }.execute(db) }
            for device in fleet { try Device.insert { device }.execute(db) }
            try Directive.insert { directive }.execute(db)
        }
    }

    private func row(_ database: any DatabaseReader) async throws -> Directive? {
        try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
    }

    @Test func extendQueueAppendsThePlannersPick() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, roamDirective(), [
            star("CENTRE", x: 0, scanned: true),
            star("NEAR", x: 2),
            star("FAR", x: 40),
        ])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")
            let updated = try await row(database)
            #expect(updated?.targets == ["NEAR"])
        }
    }

    /// The regression for the trap this resolver exists to avoid. The action the
    /// machine returns AFTER the append gets applied to a directive row, and if
    /// that row is the pre-append value the append is rolled straight back —
    /// `targets` would come out `[]` and the run would extend forever without
    /// ever going anywhere.
    @Test func theAppendSurvivesTheActionAppliedAfterIt() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, roamDirective(), [
            star("CENTRE", x: 0, scanned: true),
            star("NEAR", x: 2),
        ])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            // Whatever the machine decided next, the queue must still hold the
            // target that was just planned for it.
            let updated = try await row(database)
            #expect(updated?.targets == ["NEAR"])
            #expect(updated?.currentTarget == "NEAR")
        }
    }

    @Test func nothingLeftToSurveyCompletesTheRun() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, roamDirective(), [
            star("CENTRE", x: 0, scanned: true),
            star("DONE", x: 2, scanned: true),
        ])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")
            let updated = try await row(database)
            #expect(updated?.status == .completed)
        }
    }

    /// The regression for a stall that hit EVERY surveyed system in a live run:
    /// `unreachableDevice` moments after the queue was extended, cleared by a
    /// Retry that changed nothing about the world.
    ///
    /// The re-ask after an append can legitimately answer `.refreshDevices` —
    /// preflight demands one read round before it trusts staging rows older than
    /// `SurveyRun.stagingFreshness`, and at the end of a survey cycle they always
    /// are: a cycle runs longer than five minutes and nothing touches the drone
    /// rows while it does. That request has to be RESOLVED like any other. Handing
    /// it to the executor unresolved makes it an instant stall on its carried
    /// reason, naming a device problem that does not exist.
    @Test func aRefreshDemandedAfterTheAppendIsPaidForRatherThanStalled() async throws {
        let database = try GameDatabase.bootstrap()
        // A thousand seconds old against a five-minute freshness bar: preflight
        // will not act on these rows without reading them first.
        try await seed(
            database, roamDirective(),
            [star("CENTRE", x: 0, scanned: true), star("NEAR", x: 2)],
            devices: stagedFleet(updatedAt: Date(timeIntervalSince1970: 0))
        )

        let reads = LockIsolated<[String]>([])
        let repaired = stagedFleet(updatedAt: Date(timeIntervalSince1970: 1_000))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                reads.withValue { $0.append(code) }
                guard let row = repaired.first(where: { $0.deviceCode == code }) else { return nil }
                // The live refresher WRITES what it read, and the resolver judges
                // the re-read world rather than this return value — so a stub that
                // only returns leaves the rows as stale as it found them.
                try? await database.write { db in try Device.upsert { row }.execute(db) }
                return row
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let updated = try await row(database)
            #expect(updated?.status == .running)
            #expect(updated?.attentionReason == nil)
            #expect(updated?.targets == ["NEAR"])
            // Preflight's verdict once the rows are worth trusting: claim the
            // controller and set off.
            #expect(updated?.controllerCode == "AMI1")
            #expect(updated?.step == SurveyRun.Step.travelling)
        }
        #expect(reads.value.sorted() == ["AMI1", "DRONE1", "VES1"])
    }

    /// A system this run has already aimed at is never offered again — the
    /// exclusion that stops an uncompletable system pinning the band and stops
    /// the user's Skip being undone.
    @Test func alreadyAttemptedSystemsAreNotOfferedAgain() async throws {
        let database = try GameDatabase.bootstrap()
        // The queue already holds NEAR and the index has moved past it: NEAR was
        // aimed at and left behind, exactly as Skip leaves it. NEAR is still
        // unscanned — an uncompletable system looks precisely like this.
        try await seed(database, roamDirective(targets: ["NEAR"], targetIndex: 1), [
            star("CENTRE", x: 0, scanned: true),
            star("NEAR", x: 2),
            star("NEXT", x: 4),
        ])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")
            let updated = try await row(database)
            #expect(updated?.targets == ["NEAR", "NEXT"])
        }
    }
}
