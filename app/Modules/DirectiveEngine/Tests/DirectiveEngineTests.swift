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

    /// Scripted actions can't express a plan, so borrow the survey roam's — the
    /// tests that script an `.extendQueue` are about the resolver's wiring (the
    /// append surviving the action applied after it), not about the ranking.
    func plan(_ context: RoamContext) -> RoamPlan { SurveyRun().plan(context) }
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

        let capturedOwner = LockIsolated<CommandOwner?>(nil)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatchOwned = { _, _, _, owner in
                capturedOwner.setValue(owner)
                return .dispatched(.accepted(operationID: "OP1"))
            }
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
            #expect(entries.last?.summary == "Dispatched travel to VES1 — SOL",
                     "a travel's dispatch entry names its destination")
        }

        // The owner reaches the governor before the step advances, so it names
        // the STARTING step, and `since` is that step's own `stepStartedAt`.
        let owner = try #require(capturedOwner.value)
        #expect(owner.directiveID == "D1")
        #expect(owner.step == "start")
        #expect(owner.since == Date(timeIntervalSince1970: 0))
    }

    /// A `set_directive` repoint names the pile it's pointing the controller
    /// at — `configuration`'s `collect` — not just the generic verb, which is
    /// what let 112 identical Haul Run repoints drown in a run's timeline.
    @Test func setDirectiveDispatchNamesTheCollectPile() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .dispatch(kind: .setDirective, deviceCode: "AMI1",
                          params: CommandParams(directive: "auto:haul", configuration: [
                              "collect": .string("OCHIRD-5-1"),
                              "deliver": .string("OCHIRD-3-1"),
                          ]),
                          nextStep: "dispatched"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in .dispatched(.accepted(operationID: "OP1")) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")

            let entries = try await database.read { db in
                try DirectiveLogEntry.order { $0.id }.fetchAll(db)
            }
            #expect(entries.last?.summary == "Dispatched set_directive to AMI1 — collect OCHIRD-5-1")
        }
    }

    /// A dispatch whose params carry nothing worth naming degrades to the old
    /// text exactly — no trailing separator dangling off an empty detail.
    @Test func dispatchWithEmptyParamsDegradesToTheOldSummary() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .dispatch(kind: .simple("launch"), deviceCode: "VES1",
                          params: CommandParams(), nextStep: "launching"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in .dispatched(.accepted(operationID: "OP1")) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")

            let entries = try await database.read { db in
                try DirectiveLogEntry.order { $0.id }.fetchAll(db)
            }
            #expect(entries.last?.summary == "Dispatched launch to VES1")
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
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in .deferred(.budgetExhausted) }
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
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in .dispatched(.rejected("device busy")) }
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
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in
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
            // Only `.assignController` stamps a device onto its step entry; every
            // other transition leaves it nil, which is what keeps the built-in
            // History pane free of mission chatter (`DirectiveTimeline.fetch`).
            #expect(entries.map(\.deviceCode) == [nil])
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
            // The claimed controller is stamped onto the timeline entry too, not
            // just onto the row's column. This is load-bearing rather than
            // decorative: `HaulRun.dispatchAttemptCount` reads `deviceCode` back
            // off these `.stepStarted` entries to scope its re-entry budget to
            // ONE controller. Drop the stamp and the count silently reads zero
            // forever, the budget guard becomes dead code, and the unbounded
            // `set_directive` loop it exists to bound comes back.
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
            #expect(entries.map(\.deviceCode) == ["AMI1"])
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

    /// `.refreshBody` performs the per-body read — the only one that can observe
    /// a DELISTED salvage site — then advances.
    @Test func refreshBodyReadsThenAdvances() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "awaiting") }.execute(db)
        }
        let asked = LockIsolated<String?>(nil)
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshBody(system: "SOL", body: "SOL-3", nextStep: "verifying")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.system = { designation in
                StarSystem(designation: designation)
            }
            $0.locationsClient.body = { designation in
                asked.setValue(designation)
                return .planet(Planet(designation: designation, recon: .scanned))
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            #expect(asked.value == "SOL-3")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "verifying")
        }
    }

    /// A body read that fails still advances — best-effort, exactly like
    /// `.refreshSystem`, so a transient miss cannot strand the mission.
    @Test func refreshBodyAdvancesEvenWhenTheReadFails() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "awaiting") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshBody(system: "SOL", body: "SOL-3", nextStep: "verifying")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.system = { _ in throw LocationsError.noReplicantInSystem }
            $0.locationsClient.body = { _ in throw LocationsError.notFound }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "verifying")
        }
    }

    /// `.setDeviceTags` PATCHes the new set, confirm-reads the device, then
    /// advances — modeled on `.refreshSystem`, but with a follow-up read
    /// instead of a preceding one.
    @Test func setDeviceTagsUpdatesThenConfirmReadsThenAdvances() async throws {
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
        let patched = LockIsolated<(String, [String])?>(nil)
        let refreshed = LockIsolated<String?>(nil)
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.updateTags = { deviceCode, tags in
                patched.setValue((deviceCode, tags))
            }
            $0.deviceRefresher.refresh = { code, priority in
                refreshed.setValue(code)
                #expect(priority == .high)
                return nil
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            #expect(patched.value?.0 == "RELAY")
            #expect(patched.value?.1 == ["operator:keep"])
            #expect(refreshed.value == "RELAY")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "configuring")
            #expect(directive?.status == .running)
        }
    }

    /// A rejected/failed PATCH must never strand the run: the relay is up and
    /// meshing, and the tag is housekeeping — the same best-effort contract as
    /// `.refreshSystem`.
    @Test func setDeviceTagsAdvancesEvenWhenTheUpdateFails() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "confirmingRelay") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .setDeviceTags(deviceCode: "RELAY", tags: [], nextStep: "configuring"),
            ])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.updateTags = { _, _ in throw DevicesClient.TagUpdateError("nope") }
            $0.deviceRefresher.refresh = { _, _ in
                Issue.record("must not confirm-read after a failed update")
                return nil
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "configuring")
            #expect(directive?.status == .running)
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

/// `.refreshFleet` is `.refreshDevicesInSystem`'s counterpart for containment: a
/// tag filter never touches `location`, so a stowed device — invisible to a
/// location-scoped read — still comes back. Verified live 2026-07-30: a tagged
/// fleet caught mid-flight (six drones and a controller stowed aboard a
/// travelling vessel, all eight with `location: null`) came back complete from
/// `GET devices/tags/{tag}`, stow columns intact.
@Suite("DirectiveEngine — fleet-tag refresh")
struct DirectiveRefreshFleetTests {
    /// One tag request, and every device it returns is reconciled — so the
    /// machine's second answer is computed against rows that now exist. Mirrors
    /// `readsTheSystemOnceAndReconcilesEveryDevice`.
    @Test func refreshFleetReadsTheTagThenReAsksTheMachine() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let reads = LockIsolated<[String]>([])
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
                .advanceStep(nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchByTag = { tag in
                reads.withValue { $0.append(tag) }
                return [carrier("DRONE")]
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .running)
            #expect(directive?.step == "travelling")
            #expect(directive?.attentionReason == nil)
            let stored = try await database.read { db in
                try Device.all.fetchAll(db).map(\.deviceCode)
            }
            #expect(stored == ["DRONE"])
        }
        // Exactly one request for the whole tagged fleet.
        #expect(reads.value == ["auto:salvage"])
    }

    /// Asked twice with an authoritative tag read in between and still
    /// unresolved: the carried reason surfaces. Bounded to ONE round — a machine
    /// that asks again after the re-ask gets the carried stall, never a loop.
    @Test func refreshFleetStallsWhenTheMachineStillWantsARefresh() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let reads = LockIsolated<[String]>([])
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
                .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchByTag = { tag in
                reads.withValue { $0.append(tag) }
                return []
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .noMiningDroneAboard)
        }
        #expect(reads.value == ["auto:salvage"], "one refresh round per evaluation, never a loop")
    }

    /// A nil fallback waits instead of stalling — matches `.refreshDevicesInSystem`'s
    /// `aNilFallbackWaitsInsteadOfStalling`.
    @Test func aNilFallbackWaitsInsteadOfStalling() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshFleet(tag: "auto:salvage", thenStall: nil),
                .refreshFleet(tag: "auto:salvage", thenStall: nil),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchByTag = { _ in [] }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.status == .running)
            #expect(directive?.attentionReason == nil)
        }
    }

    /// A failed read must not strand the run and must not prune: a tag walk is
    /// NOT the authoritative full fleet, so treating its absences as "device
    /// gone" would delete the fleet. Mirrors
    /// `aFailedReadHonoursTheFallbackAndPrunesNothing`.
    @Test func aFailedReadHonoursTheFallbackAndPrunesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
            try Device.insert { carrier("ELSEWHERE") }.execute(db)
        }
        struct ReadFailure: Error {}
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
                .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
            ])],
            tick: .seconds(5)
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchByTag = { _ in throw ReadFailure() }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.attentionReason == .noMiningDroneAboard)
            let stored = try await database.read { db in
                try Device.all.fetchAll(db).map(\.deviceCode)
            }
            #expect(stored == ["ELSEWHERE"])
        }
    }

    /// Regression for the untested combination flagged in review: `.extendQueue`
    /// followed by `.refreshFleet` in the same evaluation. `resolveExtendQueue`
    /// hands its own freshly-appended `directive` value into
    /// `resolveFleetRefresh` and carries it back out as the `Resolution` the
    /// executor commits — get that wiring wrong and the append rolls itself
    /// back exactly like the trap `theAppendSurvivesTheActionAppliedAfterIt`
    /// guards for `.refreshDevices`, just one refresh case over.
    @Test func anExtendQueueAppendSurvivesAFollowingRefreshFleet() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start", targets: [], targetIndex: 0) }.execute(db)
            try Star.insert {
                Star(
                    designation: "CENTRE", spectralType: "G", color: "yellow",
                    positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 3,
                    explored: false, hasLife: nil, entryPoint: nil,
                    createdAt: Date(timeIntervalSince1970: 0), firstVisitedAt: nil,
                    fullyScannedAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try Star.insert {
                Star(
                    designation: "NEAR", spectralType: "G", color: "yellow",
                    positionX: 2, positionY: 0, positionZ: 0, estimatedPlanets: 3,
                    explored: false, hasLife: nil, entryPoint: nil,
                    createdAt: Date(timeIntervalSince1970: 0), firstVisitedAt: nil,
                    fullyScannedAt: nil
                )
            }.execute(db)
        }
        let reads = LockIsolated<[String]>([])
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .extendQueue(centre: "CENTRE"),
                .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
                .advanceStep(nextStep: "travelling"),
            ])],
            tick: .seconds(5)
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.devicesClient.fetchByTag = { tag in
                reads.withValue { $0.append(tag) }
                return []
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
        }

        let directive = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        // The trap this test guards: applying the post-refresh action to the
        // PRE-extend directive value would write `targets` back to `[]` and
        // roll the append away. Reading the persisted row is what catches it —
        // asserting on the scripted machine's inputs would not.
        #expect(directive?.targets == ["NEAR"])
        #expect(directive?.step == "travelling")
        #expect(directive?.status == .running)
        // One refresh round for the whole evaluation, even though both the
        // extend's re-ask and the refresh's re-ask call into the machine.
        #expect(reads.value == ["auto:salvage"])
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

// MARK: - Salvage roam resolution

/// The seam a Critical review finding lived in: `.extendQueue` used to run
/// `SurveyRoamPlanner` for every directive kind, so `SalvageTargetPlanner` had
/// zero production callers and a Salvage Run planned its targets with the exact
/// INVERSE filter — the survey planner offers only stars that are *not* fully
/// scanned, while salvage is only ever known in systems the survey has already
/// finished.
///
/// Driven end to end through `evaluateOnce` with the real `SalvageRun`, because
/// the whole bug was in which planner the engine reached for: a unit test of
/// `SalvageTargetPlanner` passed throughout and proved nothing.
@Suite("DirectiveEngine salvage roam resolution")
struct DirectiveEngineSalvageRoamTests {
    private func star(_ designation: String, x: Double, scanned: Bool) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0), firstVisitedAt: nil,
            fullyScannedAt: scanned ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    private func device(
        _ code: String, type: String, location: String?,
        features: [String] = [], status: String = "idle"
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1",
            status: status, location: location, locationName: nil,
            operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: features, tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func salvageDirective() -> Directive {
        Directive(
            id: "D1", kind: .salvageRun, status: .running, deviceCode: "VES1",
            controllerCode: nil, roamCentre: "CENTRE", fleetTag: "auto:salvage",
            targets: [], targetIndex: 0,
            step: SalvageRun().firstStep,
            stepStartedAt: Date(timeIntervalSince1970: 1_000),
            returnToOrigin: false, originDesignation: "CENTRE", attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// CENTRE and RICH are both meshed and fully scanned; RICH is 5 ly out and
    /// the only system carrying assayed salvage; NEAR is 1 ly out and UNSCANNED,
    /// holding nothing. RICH carries its own relay because a Salvage Run works
    /// only already-meshed systems — `tendMesh` is the sole mesh authority.
    ///
    /// The two planners disagree by construction: `SurveyRoamPlanner` can only
    /// ever pick NEAR (RICH and CENTRE are excluded by `fullyScannedAt != nil`),
    /// and `SalvageTargetPlanner` can only ever pick RICH.
    private func seed(_ database: any DatabaseWriter, assays: [SiteAssay]) async throws {
        try await database.write { db in
            for star in [
                star("CENTRE", x: 0, scanned: true),
                star("NEAR", x: 1, scanned: false),
                star("RICH", x: 5, scanned: true),
            ] { try Star.insert { star }.execute(db) }
            try Device.insert { device("VES1", type: "heaven_vessel", location: "CENTRE-1") }.execute(db)
            try Device.insert {
                device("RLY1", type: "ftl_relay", location: "CENTRE-1",
                       features: ["relay"], status: "relaying")
            }
            .execute(db)
            try Device.insert {
                device("RLY2", type: "ftl_relay", location: "RICH-1",
                       features: ["relay"], status: "relaying")
            }
            .execute(db)
            for assay in assays { try SiteAssay.insert { assay }.execute(db) }
            try Directive.insert { salvageDirective() }.execute(db)
        }
    }

    private func richAssay() -> SiteAssay {
        SiteAssay(
            id: "RICH-2-SAL-1", body: "RICH-2", system: "RICH", siteType: "salvage",
            totals: ["structural": 900], assayedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// RICH, but drained: proves `depleted` — not units — is what keeps a spent
    /// site out of the ranking, through the full engine path rather than the
    /// pure planner.
    private func depletedRichAssay() -> SiteAssay {
        SiteAssay(
            id: "RICH-2-SAL-1", body: "RICH-2", system: "RICH", siteType: "salvage",
            totals: ["structural": 900], assayedAt: Date(timeIntervalSince1970: 0),
            depleted: true
        )
    }

    private func row(_ database: any DatabaseReader) async throws -> Directive? {
        try await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
    }

    @Test func aSalvageRunPlansWithTheSalvagePlannerNotTheSurveyOne() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, assays: [richAssay()])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            // Preflight's staging check follows the append; the fleet is
            // deliberately unstaged, so it asks for a tag read and then stalls.
            // The assertion here is about the TARGET, not the step reached.
            $0.devicesClient.fetchByTag = { _ in [] }
        } operation: {
            let core = DirectiveEngineCore(machines: [SalvageRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let updated = try await row(database)
            // RICH is what the salvage ranking picks. NEAR is what the survey
            // roam would have picked — and a run sent there would have found no
            // salvage yet still deployed and activated a 370-unit relay before
            // moving on to do it again.
            #expect(updated?.targets == ["RICH"])
            #expect(updated?.currentTarget == "RICH")
        }
    }

    /// The counterpart: with no salvage known anywhere, a Salvage Run IDLES. It
    /// must not complete — the launcher, the list row and the design all promise
    /// a run that ends only on cancel, and the frontier is a moving snapshot that
    /// the survey roam keeps refilling.
    @Test func aSalvageRunWithNothingReachableIdlesRatherThanCompleting() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, assays: [])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let core = DirectiveEngineCore(machines: [SalvageRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let updated = try await row(database)
            #expect(updated?.status == .running)
            #expect(updated?.targets == [])
            #expect(updated?.attentionReason == nil)
        }
    }

    /// A depleted site is not merely a poor pick, it must be invisible to the
    /// ranking: RICH is the only system holding any assayed salvage at all, but
    /// its assay is marked `depleted`, so the run must idle exactly as it would
    /// with no assays seeded at all — never target RICH just because nothing
    /// else out-ranks it.
    @Test func aSalvageRunWithOnlyADepletedSiteIdlesRatherThanTargetingIt() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, assays: [depletedRichAssay()])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let core = DirectiveEngineCore(machines: [SalvageRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let updated = try await row(database)
            #expect(updated?.status == .running)
            #expect(updated?.targets == [])
            #expect(updated?.attentionReason == nil)
        }
    }

    /// A system already aimed at is never offered again, so a run that drained
    /// its only reachable system idles instead of looping back onto it.
    @Test func anAttemptedSalvageSystemIsNotOfferedAgain() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, assays: [richAssay()])
        try await database.write { db in
            var directive = try Directive.where { $0.id.eq("D1") }.fetchOne(db)!
            directive.targets = ["RICH"]
            directive.targetIndex = 1
            try Directive.upsert { directive }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let core = DirectiveEngineCore(machines: [SalvageRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let updated = try await row(database)
            #expect(updated?.targets == ["RICH"])
            #expect(updated?.status == .running)
        }
    }
}

/// The 2026-08-01 `Already at destination` incident, replayed end to end.
///
/// Salvage Run `BCC18F1C` stalled `commandRejected` in `positioning` at
/// 01:37:34 — **139 ms** after the `travel.arrived` event for vessel `C7836770`
/// at ALZEPHINA-7-4. `GameSync.deviceRoute` settles that one event in two
/// separate transactions: `Reconciler.applyOperationEvent` closes the travel op
/// first, `Reconciler.applyEventFields` writes `device.location` second. The
/// tick landed in the gap, so the op was closed (nothing held the step) while
/// the vessel row still said ALZEPHINA-6-23, and `positioning` re-commanded
/// travel to a body the vessel was already parked at.
///
/// Driven through `evaluateOnce` with the real `SalvageRun` rather than as a
/// unit test of `position`, because that is the only shape that is a genuine
/// regression guard: a unit test of `position` alone passed throughout the
/// live incident. What the engine reads — `dispatchedOperations`, scoped to
/// this directive's own `.commandDispatched` entries — is assembled by
/// `WorldSnapshot.read`, and only this path exercises that assembly.
@Suite("DirectiveEngine — salvage arrival freshness")
struct DirectiveEngineSalvageArrivalFreshnessTests {
    /// The instant travel op `1F616245` closed (`lastConfirmedAt`, 01:37:33.000).
    private static let arrival = Date(timeIntervalSince1970: 1_000)
    /// The tick that re-commanded travel, 139 ms later.
    private static let tick = arrival.addingTimeInterval(0.139)
    /// The vessel row as the incident left it: 123 s behind the arrival.
    private static let staleStamp = arrival.addingTimeInterval(-123)

    /// The vessel, still claiming the body it departed from.
    private func vessel(updatedAt: Date) -> Device {
        Device(
            deviceCode: "C7836770", deviceType: "heaven_vessel", replicantCode: "R1",
            status: "idle", location: "ALZEPHINA-6-23", locationName: nil,
            operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
            features: [], tags: [], detail: .object([:]),
            updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// ALZEPHINA holding exactly one live salvage body — ALZEPHINA-7-4, the one
    /// the vessel had just arrived at — so `nextBody` can only ever name it and
    /// the re-commanded destination is unambiguous.
    private var alzephina: StarSystem {
        StarSystem(
            designation: "ALZEPHINA",
            planets: [
                Planet(designation: "ALZEPHINA-7", moons: [
                    Moon(designation: "ALZEPHINA-7-4", salvage: [
                        SalvageSite(designation: "ALZEPHINA-7-4-SAL-1", resourcesAvailable: ["structural"]),
                    ]),
                ]),
            ]
        )
    }

    private func salvageDirective() -> Directive {
        Directive(
            id: "D1", kind: .salvageRun, status: .running, deviceCode: "C7836770",
            controllerCode: nil, roamCentre: "ALZEPHINA", fleetTag: "auto:salvage",
            targets: ["ALZEPHINA"], targetIndex: 0,
            step: SalvageRun.Step.positioning,
            stepStartedAt: Self.arrival.addingTimeInterval(-128),
            returnToOrigin: false, originDesignation: "ALZEPHINA", attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// The op the engine's watermark comes from, plus the `.commandDispatched`
    /// entry that scopes it into `WorldSnapshot.dispatchedOperations`. Both are
    /// required: without the log entry the op is invisible to the snapshot, and
    /// the gate would silently take its cold-run arm.
    private func seed(_ database: any DatabaseWriter, vesselUpdatedAt: Date) async throws {
        let detail = try SystemDetail(system: alzephina, hydratedAt: Date(timeIntervalSince1970: 0))
        try await database.write { db in
            try Device.insert { vessel(updatedAt: vesselUpdatedAt) }.execute(db)
            try SystemDetail.upsert { detail }.execute(db)
            try SiteAssay.insert {
                SiteAssay(
                    id: "ALZEPHINA-7-4-SAL-1", body: "ALZEPHINA-7-4", system: "ALZEPHINA",
                    siteType: "salvage", totals: ["structural": 900],
                    assayedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
            try GameModels.Operation.insert {
                GameModels.Operation(
                    id: "1F616245", entityCode: "C7836770", kind: OperationKind.travel.rawValue,
                    status: .completed, source: .event,
                    startedAt: Self.arrival.addingTimeInterval(-120), completesAt: nil,
                    lastConfirmedAt: Self.arrival, detail: .object([:])
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L-DISPATCH", directiveID: "D1", deviceCode: "C7836770",
                    kind: .commandDispatched, summary: "travel ALZEPHINA-7-4",
                    step: SalvageRun.Step.positioning, operationID: "1F616245", eventID: nil,
                    occurredAt: Self.arrival.addingTimeInterval(-120)
                )
            }.execute(db)
            try Directive.insert { salvageDirective() }.execute(db)
        }
    }

    private func row(_ database: any DatabaseReader) async throws -> Directive? {
        try await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
    }

    /// The incident itself. The travel op is closed, the vessel row is 123 s
    /// behind it and still names ALZEPHINA-6-23, and the evaluation lands 139 ms
    /// after the arrival. Nothing may be commanded off that row — and nothing
    /// may stall either: this is a race that resolves itself, not a fault.
    ///
    /// `commandGovernor.dispatch` is deliberately left unstubbed, so a
    /// re-commanded travel fails the test loudly at the point it is issued
    /// rather than only via the assertions below.
    @Test func aVesselRowLaggingTheArrivalNeitherReCommandsTravelNorStalls() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, vesselUpdatedAt: Self.staleStamp)
        let reads = LockIsolated<[String]>([])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.tick)
            $0.uuid = .incrementing
            // The read does not land. That is the hostile case for the gate: the
            // row stays stale through the re-ask, so `reAsk` must collapse the
            // repeat request into a wait rather than escalating.
            $0.deviceRefresher.refresh = { code, _ in
                reads.withValue { $0.append(code) }
                return nil
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [SalvageRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let updated = try await row(database)
            #expect(updated?.step == SalvageRun.Step.positioning)
            #expect(updated?.status == .running, "a self-resolving race must not need a human")
            #expect(updated?.attentionReason == nil)

            // The audit pass logs the arrival it just noticed (`.opCompleted`),
            // which is right — but there must be no SECOND `.commandDispatched`,
            // because that is the re-commanded travel the server rejected.
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind).sorted { $0.rawValue < $1.rawValue }
                    == [.commandDispatched, .opCompleted])
            #expect(entries.filter { $0.kind == .commandDispatched }.map(\.id) == ["L-DISPATCH"],
                    "the seeded dispatch only — no re-commanded travel")
        }
        #expect(reads.value == ["C7836770"], "exactly one authoritative read, never a loop")
    }

    /// The proof that the test above is not vacuous. Same fixture, same closed
    /// travel op, same origin location — only the vessel row's `updatedAt` moves
    /// forward to the arrival instant, and the run dispatches travel exactly as
    /// it did before the gate existed. So the freshness of the row is the ONLY
    /// thing standing between this fixture and a command, which is what makes
    /// the wait above meaningful rather than an accident of the fixture.
    @Test func theSameFixtureWithARowPostDatingTheArrivalStillDispatchesTravel() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, vesselUpdatedAt: Self.arrival)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.tick)
            $0.uuid = .incrementing
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in .dispatched(.accepted(operationID: "OP-NEW")) }
        } operation: {
            let core = DirectiveEngineCore(machines: [SalvageRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let updated = try await row(database)
            #expect(updated?.status == .running)
            #expect(updated?.attentionReason == nil)

            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.contains { $0.operationID == "OP-NEW" })
        }
    }
}

/// A machine that asks for a footprint refresh once and then waits, so an
/// evaluation exercises exactly this action. `thenStall: nil` mirrors
/// `HaulRun.survey`'s own contract (advance anyway on a transient miss,
/// never escalate) — see `EscalatingFootprintRefreshMachine` below for the
/// other real contract, `RelayRun.acquire`'s.
private struct FootprintRefreshMachine: MissionStepMachine {
    let kind: DirectiveKind = .haulRun
    let firstStep = "surveying"
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        directive.step == "surveying"
            ? .refreshFootprint(nextStep: "assigning", thenStall: nil)
            : .wait
    }
    func plan(_ context: RoamContext) -> RoamPlan { .idle }
}

/// A machine that always wants a footprint refresh with a REAL `thenStall`,
/// regardless of the world it's handed — the shape `RelayRun.acquire` uses in
/// production, where a persistently-unreadable census sits in front of an
/// irreversible spend and must escalate rather than retry forever.
private struct EscalatingFootprintRefreshMachine: MissionStepMachine {
    let kind: DirectiveKind = .haulRun
    let firstStep = "surveying"
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        .refreshFootprint(nextStep: "surveying", thenStall: .printStockShort)
    }
    func plan(_ context: RoamContext) -> RoamPlan { .idle }
}

@Suite("MissionAction .refreshFootprint")
struct RefreshFootprintTests {

    private func haulDirective() -> Directive {
        Directive(
            id: "D1", kind: .haulRun, status: .running, deviceCode: "CTRL1",
            targets: [], targetIndex: 0, step: "surveying",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// The headline: the refresh is issued, and the step advances.
    @Test func itRefreshesTheFootprintThenAdvances() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { haulDirective() }.execute(db)
        }
        let refreshed = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.footprint = {
                refreshed.withValue { $0 += 1 }
                return ["ATIANFU-BELT-1": LocationCounts(
                    locationEvents: 0, devices: 0, resourceSites: 0,
                    resources: 3_537, replicants: 0
                )]
            }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [FootprintRefreshMachine()], tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "D1")
        }

        #expect(refreshed.value == 1)
        let row = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        #expect(row?.step == "assigning")
    }

    /// Best-effort by contract: a failed read must advance the run anyway. The
    /// machine re-asks for a refresh on its next cycle, so a transient network
    /// failure costs one cycle rather than stranding the run.
    @Test func aFailedRefreshStillAdvances() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { haulDirective() }.execute(db)
        }
        struct Boom: Error {}

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.footprint = { throw Boom() }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [FootprintRefreshMachine()], tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "D1")
        }

        let row = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        #expect(row?.step == "assigning")
        #expect(row?.status == .running)
        #expect(row?.attentionReason == nil)
    }

    /// **Termination proof, at the real engine — not just the pure mission
    /// function.** Review round 2 bounded "one location missing from an
    /// otherwise-successful census refresh." This proves the OTHER
    /// pathological case is also bounded: the refresh request itself
    /// persistently failing outright (an offline network, an expired token,
    /// sustained 5xx/429 — strictly more common than the round-2 case, not
    /// rarer). A machine using `thenStall` (`RelayRun.acquire`'s real
    /// contract) must escalate to a stall after exactly ONE round, and a
    /// stalled directive must never be auto-re-evaluated — proven here end to
    /// end through `DirectiveEngineCore.evaluateOnce` and
    /// `DirectiveExecutor.apply`, the real machinery, not a fixture standing
    /// in for it.
    @Test func persistentlyFailingFootprintRefreshEscalatesAfterOneRound() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { haulDirective() }.execute(db)
        }
        struct Boom: Error {}
        let attempts = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.footprint = {
                attempts.withValue { $0 += 1 }
                throw Boom()
            }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [EscalatingFootprintRefreshMachine()], tick: .seconds(5)
            )
            // TWO full evaluations — the second is what proves the stall
            // actually STOPS the loop rather than merely delaying it by one
            // tick: a naive fix might still escalate on evaluation 1 but keep
            // retrying on every subsequent one.
            await core.evaluateOnce(directiveID: "D1")
            await core.evaluateOnce(directiveID: "D1")
        }

        #expect(attempts.value == 1, "a stalled (non-running) directive must never be auto-re-evaluated")
        let row = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        #expect(row?.status == .needsAttention)
        #expect(row?.attentionReason == .printStockShort)
        #expect(row?.step == "surveying", "must not have advanced — it escalated instead")
    }
}

// MARK: - Chained refresh kinds

/// A machine that asks for a DIFFERENT refresh kind every single time it is
/// asked, cycling through all four forever and never settling — the adversary
/// `reAsk`'s chain bound exists to survive.
///
/// It is deliberately insatiable. A machine that eventually answered something
/// else would prove only that THIS fixture terminates; the bound being claimed
/// is that the engine terminates *whatever the machine says*, which only an
/// endlessly-demanding machine can demonstrate.
private struct RefreshCarouselMachine: MissionStepMachine {
    let kind: DirectiveKind = .surveyRun
    let firstStep = "start"
    /// How many times the machine has been asked, across the whole evaluation.
    let asks = LockIsolated(0)

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        let n = asks.withValue { $0 += 1; return $0 }
        // Each kind carries a DISTINCT reason, so the stall that ends the chain
        // also pins WHICH action's reason was honoured.
        switch (n - 1) % 4 {
        case 0: return .refreshDevices(deviceCodes: ["VES1"], thenStall: .unreachableDevice)
        case 1: return .refreshFootprint(nextStep: "start", thenStall: .printStockShort)
        case 2: return .refreshFleet(tag: "auto:survey", thenStall: .noSurveyDroneAboard)
        default: return .refreshDevicesInSystem(designation: "SOL", thenStall: .noSurveyControllerAboard)
        }
    }

    func plan(_ context: RoamContext) -> RoamPlan { .idle }
}

/// The engine's chain guard: a re-ask that raises a *different* refresh kind is
/// paid for once, a re-ask that repeats a kind already paid for is collapsed —
/// and the whole chain is bounded by the number of refresh kinds that exist.
@Suite("DirectiveEngine — chained refresh kinds")
struct RefreshChainTests {

    // MARK: The bound

    /// **The termination proof for chaining.** `paid` is a set over
    /// `RefreshKind`, a closed four-case enum; every hop is guarded on
    /// `!paid.contains(kind)` and inserts before recursing, so at most four
    /// refresh rounds — one per kind — can ever happen in a single evaluation,
    /// after which the chain must end in a non-refresh action.
    ///
    /// This drives the real `DirectiveEngineCore` with a machine that demands a
    /// fresh kind every time it is asked, forever. Exactly one read of each of
    /// the four kinds is performed, and then the fifth ask — the first repeat —
    /// collapses to a stall rather than buying a fifth round.
    @Test func aChainIsBoundedByOneRoundPerRefreshKind() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let deviceReads = LockIsolated<[String]>([])
        let footprintReads = LockIsolated(0)
        let fleetReads = LockIsolated<[String]>([])
        let systemReads = LockIsolated<[String]>([])
        let machine = RefreshCarouselMachine()
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                deviceReads.withValue { $0.append(code) }
                return carrier(code)
            }
            $0.locationsClient.footprint = {
                footprintReads.withValue { $0 += 1 }
                return [:]
            }
            $0.devicesClient.fetchByTag = { tag in
                fleetReads.withValue { $0.append(tag) }
                return []
            }
            $0.devicesClient.fetchAtLocation = { designation in
                systemReads.withValue { $0.append(designation) }
                return []
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            // A second full evaluation, to prove the stall STOPPED the chain
            // rather than merely deferring the rest of it by one tick.
            await core.evaluateOnce(directiveID: "D1")
        }

        #expect(deviceReads.value == ["VES1"], "at most one device-refresh round per evaluation")
        #expect(footprintReads.value == 1, "at most one footprint-refresh round per evaluation")
        #expect(fleetReads.value == ["auto:survey"], "at most one fleet-refresh round per evaluation")
        #expect(systemReads.value == ["SOL"], "at most one system-refresh round per evaluation")
        // Four resolved rounds plus the fifth ask that was refused: the chain
        // cannot be longer than the number of refresh kinds that exist.
        #expect(machine.asks.value == 5)

        let row = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        #expect(row?.status == .needsAttention)
        // The FIFTH ask's own reason — `.refreshDevices`' `.unreachableDevice` —
        // not whichever refresh happened to be paid for last (`.refreshDevicesInSystem`,
        // carrying `.noSurveyControllerAboard`). A collapse honours the action it
        // is collapsing, never the caller's.
        #expect(row?.attentionReason == .unreachableDevice)
    }

    /// The other half of the guard, unchanged from before chaining existed: a
    /// re-ask repeating the SAME kind buys nothing. Pinned separately from
    /// `DirectiveRefreshDevicesTests.aConfirmedFindingStallsWithTheCarriedReason`
    /// because that one predates `paid` and would still pass if kind-scoping
    /// were the ONLY rule and repeats were allowed to chain.
    @Test func aRepeatedKindIsRefusedEvenAfterAChain() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "start") }.execute(db)
        }
        let footprintReads = LockIsolated(0)
        let deviceReads = LockIsolated(0)
        // devices → footprint → devices: the third ask repeats a kind already
        // paid for at the START of the chain, not the one just performed.
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .unreachableDevice),
                .refreshFootprint(nextStep: "start", thenStall: .printStockShort),
                .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyDroneAboard),
            ])],
            tick: .seconds(5)
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                deviceReads.withValue { $0 += 1 }
                return carrier(code)
            }
            $0.locationsClient.footprint = {
                footprintReads.withValue { $0 += 1 }
                return [:]
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
        }

        #expect(deviceReads.value == 1, "the repeat must not buy a second device round")
        #expect(footprintReads.value == 1)
        let row = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        #expect(row?.status == .needsAttention)
        // The refused action's own reason, again — the third script entry's
        // `.noSurveyDroneAboard`, not the first's `.unreachableDevice`.
        #expect(row?.attentionReason == .noSurveyDroneAboard)
    }
}

// MARK: - RelayRun.acquire through the real engine

/// `RelayRun.acquire`'s ordinary path, driven end to end through
/// `DirectiveEngineCore` with the REAL `RelayRun` machine.
///
/// Every other `RelayRun` test is a pure-function table over a hand-built
/// `WorldSnapshot`, and no test drove `RelayRun` through the engine at all —
/// which is exactly why a defect living in the hand-off between the mission and
/// the engine's refresh resolvers went unnoticed through a whole review round.
@Suite("RelayRun — acquire through the engine")
struct RelayRunEngineTests {

    private static let hubLocation = "HUB-BELT-1"
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private func device(
        _ code: String,
        type: String,
        availableCommands: [String] = [],
        updatedAt: Date
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
            location: Self.hubLocation, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
            features: [], tags: [], detail: .object([:]),
            updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func relayDirective() -> Directive {
        Directive(
            id: "D1", kind: .relayRun, status: .running, deviceCode: "V1",
            targets: ["VEGA"], targetIndex: 0, step: "acquire",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// **The regression test for the round-3 wrong-stall defect.**
    ///
    /// The exact ordinary sequence `acquire` walks on a healthy run whose local
    /// rows have simply gone quiet:
    ///
    /// 1. the hub DEVICE row is older than `hubFreshness`, so the machine asks
    ///    for `.refreshDevices([AF1], thenStall: .unreachableDevice)`;
    /// 2. that read succeeds and the hub row goes fresh — nothing is
    ///    unreachable;
    /// 3. the re-ask gets past the device gate and finds the stockpile CENSUS
    ///    stale (empty here), so the machine asks for
    ///    `.refreshFootprint(thenStall: .printStockShort)` — a different
    ///    question, not a repeat of the one just answered.
    ///
    /// The engine must pay for that second question and let the reserve rail
    /// run. Before this fix it collapsed step 3 onto step 1's carried reason and
    /// stalled `.unreachableDevice` — halting the run, blaming a device that
    /// was fine, and never reaching the rail at all; a human Retry re-entered
    /// the same state and stalled again until the retry budget escalated.
    @Test func aStaleHubRowThenAStaleCensusReachesTheReserveRail() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Self.now
        try await database.write { db in
            try Directive.insert { relayDirective() }.execute(db)
            // The carrier is fresh; only the HUB row has gone stale, which is
            // what makes step 1 fire and step 3 reachable.
            try Device.insert { device("V1", type: "heaven_vessel", updatedAt: now) }.execute(db)
            try Device.insert {
                device(
                    "AF1", type: "autofactory", availableCommands: ["enqueue_print"],
                    updatedAt: now.addingTimeInterval(-600)
                )
            }.execute(db)
            // No `LocationFootprint` rows at all — the census is stale by
            // `RelayRun.footprintCensusIsStale`'s "never read" branch.
        }
        let deviceReads = LockIsolated<[String]>([])
        let footprintReads = LockIsolated(0)
        let dispatched = LockIsolated<[OperationKind]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                deviceReads.withValue { $0.append(code) }
                guard code == "AF1" else { return nil }
                // A genuinely successful authoritative read: the row lands
                // fresh, so the device gate is satisfied on the re-ask.
                let fresh = self.device(
                    "AF1", type: "autofactory", availableCommands: ["enqueue_print"], updatedAt: now
                )
                try? await database.write { db in try Device.upsert { fresh }.execute(db) }
                return fresh
            }
            $0.locationsClient.footprint = {
                footprintReads.withValue { $0 += 1 }
                // Abundant, and far above `BrainCeiling.aggregateSpendFloor` —
                // the rail must PERMIT here, so what is being proven is that
                // the rail ran at all, not that it vetoed.
                return [Self.hubLocation: LocationCounts(
                    locationEvents: 0, devices: 2, resourceSites: 0,
                    resources: 999_999, replicants: 0
                )]
            }
            $0.commandGovernor.dispatchOwned = { kind, _, _, _ in
                dispatched.withValue { $0.append(kind) }
                return .dispatched(.accepted(operationID: "OP1"))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [RelayRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")
        }

        #expect(deviceReads.value == ["AF1"], "the stale hub row is what step 1 reads")
        #expect(footprintReads.value == 1, "the census refresh step 3 asked for must actually be paid for")
        #expect(dispatched.value == [.print], "the reserve rail ran and permitted the print")

        let row = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        #expect(row?.status == .running)
        #expect(row?.attentionReason == nil, "nothing was unreachable and nothing was short")
        #expect(row?.step == "printing")
    }

    /// The same first two steps, but the census refresh comes back without the
    /// hub's own row — positive evidence the hub is genuinely absent from a
    /// fresh read. The rail must now VETO, and it must do so under its OWN
    /// reason (`.printStockShort`), never under the device refresh's
    /// `.unreachableDevice`.
    ///
    /// The companion to the test above: together they pin that the chained
    /// refresh reaches the rail AND that the rail's verdict — either way — is
    /// what surfaces.
    @Test func aChainedCensusRefreshStallsUnderTheRailsOwnReason() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Self.now
        try await database.write { db in
            try Directive.insert { relayDirective() }.execute(db)
            try Device.insert { device("V1", type: "heaven_vessel", updatedAt: now) }.execute(db)
            try Device.insert {
                device(
                    "AF1", type: "autofactory", availableCommands: ["enqueue_print"],
                    updatedAt: now.addingTimeInterval(-600)
                )
            }.execute(db)
        }
        let dispatched = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                guard code == "AF1" else { return nil }
                let fresh = self.device(
                    "AF1", type: "autofactory", availableCommands: ["enqueue_print"], updatedAt: now
                )
                try? await database.write { db in try Device.upsert { fresh }.execute(db) }
                return fresh
            }
            // A successful census that simply does not list the hub: every
            // OTHER location's row goes fresh, so the table-wide gate is
            // satisfied and `printStockIsShort` fails closed on the absence.
            $0.locationsClient.footprint = {
                ["SOMEWHERE-ELSE-1": LocationCounts(
                    locationEvents: 0, devices: 1, resourceSites: 0,
                    resources: 999_999, replicants: 0
                )]
            }
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in
                dispatched.withValue { $0 += 1 }
                return .dispatched(.accepted(operationID: "OP1"))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [RelayRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")
        }

        #expect(dispatched.value == 0, "an irreversible spend must never happen on an unreadable census")
        let row = try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)
        }
        #expect(row?.status == .needsAttention)
        #expect(row?.attentionReason == .printStockShort)
        #expect(row?.step == "acquire")
    }
}
