import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import DirectiveEngine

@Suite("Event mission actions")
struct EventActionTests {
    @Test("completeEvent posts once and then re-reads the ledger")
    func commitPostsAndRefreshes() async throws {
        let posted = LockIsolated<[String]>([])
        let refreshed = LockIsolated(0)
        try await withDependencies {
            $0.locationEventsClient.refresh = { refreshed.withValue { $0 += 1 }; return 1 }
            $0.locationEventsClient.complete = { location, designation in
                posted.withValue { $0.append("\(location)/\(designation)") }
            }
        } operation: {
            @Dependency(\.locationEventsClient) var client
            try await client.complete("X-1", "X-1-EVT-001")
            _ = try await client.refresh()
        }
        #expect(posted.value == ["X-1/X-1-EVT-001"])
        #expect(refreshed.value == 1)
    }

    @Test("the two new reasons classify for the brain")
    func dispositions() {
        #expect(DirectiveAttentionReason.eventCriteriaUnmet.brainDisposition == .escalate)
        #expect(DirectiveAttentionReason.eventCommitRejected.brainDisposition == .retry)
    }
}

// MARK: - The event actions through the real engine

/// A machine that answers `action` whatever it is asked, so an evaluation can be
/// driven through `DirectiveEngineCore` without a real mission's preconditions.
private struct FixedActionMachine: MissionStepMachine {
    let kind: DirectiveKind = .eventRun
    let firstStep = "step"
    let action: MissionAction
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction { action }
    func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}

/// Answers `script` in order, then repeats its last entry, so one evaluation can
/// be walked through a chain of different actions. `nextAction` must stay pure
/// for real machines; this one counts calls to prove how many the engine made.
private struct ScriptedMachine: MissionStepMachine {
    let kind: DirectiveKind = .eventRun
    let firstStep = "step"
    let script: [MissionAction]
    let calls = LockIsolated(0)

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        let index = calls.withValue { count -> Int in
            defer { count += 1 }
            return count
        }
        return script[min(index, script.count - 1)]
    }

    func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}

/// The two actions driven through `DirectiveEngineCore`, where the refresh
/// chain's termination bound and the step clock actually live — a pure-function
/// table cannot see either.
@Suite("Event actions at the engine", .serialized)
struct EventActionEngineTests {

    private static let instant = Date(timeIntervalSince1970: 100_000)
    private static let started = Date(timeIntervalSince1970: 90_000)

    private func seed(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Directive.insert {
                Directive(
                    id: "E1", kind: .eventRun, status: .running, deviceCode: "V1",
                    targets: ["SOL"], targetIndex: 0, step: "step",
                    stepStartedAt: Self.started, returnToOrigin: false,
                    originDesignation: nil, attentionReason: nil,
                    createdAt: Self.started, updatedAt: Self.started
                )
            }.execute(db)
        }
    }

    private func row(_ database: any DatabaseWriter) async throws -> Directive {
        try #require(await database.read { db in
            try Directive.where { $0.id.eq("E1") }.fetchOne(db)
        })
    }

    /// **Termination.** A machine that keeps asking for the ledger buys exactly
    /// one walk per evaluation and then collapses onto its carried reason.
    @Test func aRepeatedEventRefreshCostsOneReadAndThenStalls() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { reads.withValue { $0 += 1 }; return 3 }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [FixedActionMachine(action: .refreshEvents(thenStall: .eventCriteriaUnmet))],
                tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "E1")
        }

        #expect(reads.value == 1, "one ledger walk per evaluation, however the re-ask answers")
        let row = try await row(database)
        #expect(row.status == .needsAttention)
        #expect(row.attentionReason == .eventCriteriaUnmet)
    }

    /// **The step clock.** With no carried reason the collapse is `.wait`, the one
    /// action that leaves `stepStartedAt` alone — so a caller re-asking on its own
    /// step accumulates its deadline instead of polling forever.
    @Test func anUnresolvedEventRefreshWaitsWithoutRestampingTheStep() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { reads.withValue { $0 += 1 }; return 3 }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [FixedActionMachine(action: .refreshEvents(thenStall: nil))],
                tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "E1")
        }

        #expect(reads.value == 1)
        let row = try await row(database)
        #expect(row.status == .running)
        #expect(row.attentionReason == nil)
        #expect(row.stepStartedAt == Self.started, "a wait must never restart the step deadline")
    }

    /// A failing ledger walk is best-effort: the re-ask proceeds against the rows
    /// already held, and the run is no worse off than before the attempt.
    @Test func aFailingEventRefreshStillReAsks() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        struct Boom: Error {}
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { reads.withValue { $0 += 1 }; throw Boom() }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [FixedActionMachine(action: .refreshEvents(thenStall: nil))],
                tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "E1")
        }

        #expect(reads.value == 1)
        let row = try await row(database)
        #expect(row.status == .running)
        #expect(row.stepStartedAt == Self.started)
    }

    @Test func aCommitPostsOnceRefreshesAndAdvances() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        let posted = LockIsolated<[String]>([])
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { reads.withValue { $0 += 1 }; return 3 }
            $0.locationEventsClient.complete = { location, designation in
                posted.withValue { $0.append("\(location)/\(designation)") }
            }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [FixedActionMachine(
                    action: .completeEvent(location: "SOL-3", designation: "EVT-1", nextStep: "after")
                )],
                tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "E1")
        }

        #expect(posted.value == ["SOL-3/EVT-1"])
        #expect(reads.value == 1, "the commit is followed by exactly one ledger re-read")
        let row = try await row(database)
        #expect(row.step == "after")
        #expect(row.status == .running)
    }

    /// **The chain hop.** A device refresh whose re-ask asks for the ledger pays
    /// for the events kind ONCE: the hop hands its resolver the union, so the next
    /// `.refreshEvents` collapses instead of buying a second walk.
    @Test func aDeviceRefreshChainsIntoTheLedgerExactlyOnce() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        let deviceReads = LockIsolated(0)
        let ledgerReads = LockIsolated(0)
        let machine = ScriptedMachine(script: [
            .refreshDevices(deviceCodes: ["V1"], thenStall: nil),
            .refreshEvents(thenStall: .eventCriteriaUnmet),
            .refreshEvents(thenStall: .eventCriteriaUnmet),
            .wait,
        ])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { _, _ in deviceReads.withValue { $0 += 1 }; return nil }
            $0.locationEventsClient.refresh = { ledgerReads.withValue { $0 += 1 }; return 3 }
        } operation: {
            let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "E1")
        }

        #expect(deviceReads.value == 1)
        #expect(ledgerReads.value == 1, "the hop must pay for `.events`, not hand its resolver a bare `paid`")
        #expect(machine.calls.value == 3, "ask, re-ask after devices, re-ask after events — then collapse")
        let row = try await row(database)
        #expect(row.status == .needsAttention)
        #expect(row.attentionReason == .eventCriteriaUnmet)
    }

    /// A commit answered to a RE-ASK is resolved there, not passed to the executor
    /// unresolved — otherwise the POST silently never fires on that tick.
    @Test func aCommitAnsweredToAReAskStillPosts() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        let posted = LockIsolated<[String]>([])
        let ledgerReads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { ledgerReads.withValue { $0 += 1 }; return 3 }
            $0.locationEventsClient.complete = { location, designation in
                posted.withValue { $0.append("\(location)/\(designation)") }
            }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [ScriptedMachine(script: [
                    .refreshEvents(thenStall: .eventCriteriaUnmet),
                    .completeEvent(location: "SOL-3", designation: "EVT-1", nextStep: "after"),
                ])],
                tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "E1")
        }

        #expect(posted.value == ["SOL-3/EVT-1"], "the commit must fire on the tick the re-ask asked for it")
        #expect(ledgerReads.value == 2, "one walk for the refresh, one after the commit")
        let row = try await row(database)
        #expect(row.step == "after")
        #expect(row.status == .running)
    }

    /// A refused commit advances anyway: the mission re-judges from the refreshed
    /// row, so retrying here would only hide the refusal.
    @Test func aRefusedCommitStillRefreshesAndAdvances() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { reads.withValue { $0 += 1 }; return 3 }
            $0.locationEventsClient.complete = { _, _ in throw LocationEventError("no replicant present") }
        } operation: {
            let core = DirectiveEngineCore(
                machines: [FixedActionMachine(
                    action: .completeEvent(location: "SOL-3", designation: "EVT-1", nextStep: "after")
                )],
                tick: .seconds(5)
            )
            await core.evaluateOnce(directiveID: "E1")
        }

        #expect(reads.value == 1)
        let row = try await row(database)
        #expect(row.step == "after")
        #expect(row.status == .running)
        #expect(row.attentionReason == nil)
    }
}
