//
//  EventRunEngineTests.swift
//  Replicould — DirectiveEngine
//
//  `EventRun` driven through `DirectiveEngineCore` against a real database.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

/// The run through the real seam: a seeded database, a real `DirectiveEngineCore`
/// and real evaluations. A fixture table can see neither the refresh chain's bound
/// nor the step clock, and both are what stop this mission looping.
@Suite("EventRun through the engine", .serialized)
struct EventRunEngineTests {
    private static let now = Date(timeIntervalSince1970: 10_000)

    /// A convoy standing on site with the row on `step`, plus the depot rows that
    /// make `HUB-1` recognise as the theatre it is stamped to.
    private func seed(
        _ database: any DatabaseWriter,
        step: String,
        event: LocationEvent,
        extraDevices: [Device] = []
    ) async throws {
        let now = Self.now
        try await database.write { db in
            for device in EventRunFixtures.onSiteConvoy(updatedAt: now)
                + EventRunFixtures.depotFleet(updatedAt: now) + extraDevices
            {
                try Device.insert { device }.execute(db)
            }
            try LocationFootprint.insert { EventRunFixtures.depotFootprint(fetchedAt: now) }
                .execute(db)
            try TheatrePin.insert { TheatrePin(location: "HUB-1", createdAt: now) }.execute(db)
            try LocationEvent.insert { event }.execute(db)
            try Directive.insert { EventRunFixtures.directive(step: step, now: now) }.execute(db)
        }
    }

    private func row(_ database: any DatabaseWriter) async throws -> Directive {
        try #require(await database.read { db in
            try Directive.where { $0.id.eq("d1") }.fetchOne(db)
        })
    }

    /// Records every dispatch and moves the rows an accepted command would move,
    /// so a run can actually reach its own end rather than stalling on a hull
    /// that never arrives.
    private func governor(
        _ database: any DatabaseWriter, into log: LockIsolated<[String]>
    ) -> CommandGovernorClient {
        CommandGovernorClient { kind, deviceCode, params in
            log.withValue { $0.append(kind.rawValue) }
            try? await database.write { db in
                if kind == .travel, let destination = params.destination {
                    guard var hull = try Device.where { $0.deviceCode.eq(deviceCode) }.fetchOne(db)
                    else { return }
                    hull.location = destination
                    try Device.upsert { hull }.execute(db)
                }
                if kind == .detach {
                    for code in params.devices ?? [] {
                        guard var moved = try Device.where { $0.deviceCode.eq(code) }.fetchOne(db)
                        else { continue }
                        moved.attachedToDeviceCode = nil
                        try Device.upsert { moved }.execute(db)
                    }
                }
            }
            return .dispatched(.accepted(operationID: nil))
        }
    }

    // MARK: - Termination

    /// **Required.** A ledger that never satisfies the machine must stall, and the
    /// reads it buys on the way must be countable — one walk per evaluation, none
    /// at all once the row has left `.running`.
    @Test("a permanently unmet event stalls, bounded, rather than polling forever")
    func boundedUnmetProgress() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.confirmingProgress,
            event: EventRunFixtures.progressEvent(met: false, replicant: true)
        )
        let refreshes = LockIsolated(0)
        let clock = LockIsolated(Self.now)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .init { clock.value }
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { refreshes.withValue { $0 += 1 }; return 0 }
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            for _ in 0..<3 { await core.evaluateOnce(directiveID: "d1") }
            clock.setValue(Self.now.addingTimeInterval(EventRun.progressDeadline + 60))
            for _ in 0..<3 { await core.evaluateOnce(directiveID: "d1") }
        }

        #expect(refreshes.value == 3, "one ledger walk per polling evaluation, and none after the stall")
        let row = try await row(database)
        #expect(row.status == .needsAttention)
        #expect(row.attentionReason == .eventCriteriaUnmet)
        #expect(row.step == EventRun.Step.confirmingProgress)
        #expect(row.stepStartedAt == Self.now, "the poll must not re-stamp the deadline it is accruing")
    }

    // MARK: - The commit

    /// **Required.** The commit is not idempotent from our side, so the POST must
    /// fire exactly once however many evaluations the tail takes.
    @Test("a met event commits exactly once and finishes")
    func commitsOnce() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.committing,
            event: EventRunFixtures.progressEvent(met: true, replicant: true)
        )
        let posts = LockIsolated<[String]>([])
        let dispatches = LockIsolated<[String]>([])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.now)
            $0.uuid = .incrementing
            $0.commandGovernor = governor(database, into: dispatches)
            $0.locationEventsClient.refresh = { 1 }
            $0.locationEventsClient.complete = { location, designation in
                posts.withValue { $0.append("\(location)/\(designation)") }
                try await database.write { db in
                    guard var event = try LocationEvent
                        .where { $0.designation.eq(designation) }.fetchOne(db)
                    else { return }
                    event.status = "completed"
                    try LocationEvent.upsert { event }.execute(db)
                }
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "d1")
            // The step, not the ledger, is what stops a second POST: a row left
            // on `committing` re-posts the moment the close has not landed yet.
            let committed = try await row(database)
            #expect(committed.step == EventRun.Step.collecting)
            for _ in 0..<7 { await core.evaluateOnce(directiveID: "d1") }
        }

        #expect(posts.value == ["X-1/X-1-EVT-001"], "the commit is not idempotent — exactly one POST")
        #expect(dispatches.value == [
            OperationKind.collectResources.rawValue,
            OperationKind.travel.rawValue,
            OperationKind.travel.rawValue,
        ])
        let row = try await row(database)
        #expect(row.status == .completed)
        #expect(row.attentionReason == nil)
    }

    /// A refusal must not be retried behind the operator's back: the run advances,
    /// re-reads, and escalates once the deadline passes — still one POST.
    @Test("a refused commit escalates without ever posting twice")
    func aRefusedCommitPostsOnce() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.committing,
            event: EventRunFixtures.progressEvent(met: true, replicant: true)
        )
        let posts = LockIsolated(0)
        let refreshes = LockIsolated(0)
        let clock = LockIsolated(Self.now)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .init { clock.value }
            $0.uuid = .incrementing
            $0.locationEventsClient.refresh = { refreshes.withValue { $0 += 1 }; return 1 }
            $0.locationEventsClient.complete = { _, _ in
                posts.withValue { $0 += 1 }
                throw LocationEventError("no replicant present")
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            for _ in 0..<3 { await core.evaluateOnce(directiveID: "d1") }
            clock.setValue(Self.now.addingTimeInterval(EventRun.progressDeadline + 60))
            for _ in 0..<3 { await core.evaluateOnce(directiveID: "d1") }
        }

        #expect(posts.value == 1, "a refusal is the operator's to judge, never the engine's to re-send")
        #expect(refreshes.value == 3, "one after the commit, one per polling evaluation, none after the stall")
        let row = try await row(database)
        #expect(row.status == .needsAttention)
        #expect(row.attentionReason == .eventCommitRejected)
    }

    // MARK: - The immediate-verb loop

    /// `staging` loops over two immediate verbs, so no open operation bounds it —
    /// only the round counter read off the log rows `DirectiveExecutor` writes,
    /// whose summary line a fixture log hand-builds rather than exercises.
    @Test("the immediate-verb staging loop is bounded by the log the executor writes")
    func stagingLoopIsBoundedByItsOwnLog() async throws {
        let database = try GameDatabase.bootstrap()
        let beacon = EventRunFixtures.device(
            "BEACON", type: EventPlan.beaconDeviceType, attachedTo: "CARRIER",
            location: "X-1", updatedAt: Self.now
        )
        try await seed(
            database, step: EventRun.Step.staging,
            event: EventRunFixtures.progressEvent(met: false, replicant: true),
            extraDevices: [beacon]
        )
        let dispatches = LockIsolated<[String]>([])
        let refreshes = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.now)
            $0.uuid = .incrementing
            $0.commandGovernor = governor(database, into: dispatches)
            $0.locationEventsClient.refresh = { refreshes.withValue { $0 += 1 }; return 0 }
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            for _ in 0..<6 { await core.evaluateOnce(directiveID: "d1") }
        }

        #expect(dispatches.value == [
            OperationKind.detach.rawValue, OperationKind.depositResources.rawValue,
        ], "each leg is ordered once — the counter must survive the loop's own re-entries")
        let row = try await row(database)
        #expect(row.step == EventRun.Step.confirmingProgress)
        #expect(row.status == .running)
        #expect(refreshes.value == 1, "the handoff into the progress gate buys one ledger walk")
    }

    // MARK: - Degradation

    /// An event closed by another path is a clean abort: recover the courier, fly
    /// home, finish. No commit, and above all no stall for a human to clear.
    @Test("an event already closed aborts to a completed run without stalling")
    func alreadyClosedAbortsCleanly() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.confirmingProgress,
            event: EventRunFixtures.progressEvent(met: true, replicant: true, status: "completed")
        )
        let dispatches = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.now)
            $0.uuid = .incrementing
            $0.commandGovernor = governor(database, into: dispatches)
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            for _ in 0..<6 { await core.evaluateOnce(directiveID: "d1") }
        }

        #expect(dispatches.value == [
            OperationKind.travel.rawValue, OperationKind.travel.rawValue,
        ], "both hulls home, and nothing else ordered on an event we did not close")
        let row = try await row(database)
        #expect(row.status == .completed)
        #expect(row.attentionReason == nil)
    }
}
