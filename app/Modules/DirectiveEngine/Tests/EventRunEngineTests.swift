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
        extraDevices: [Device] = [],
        blueprints: [Blueprint] = []
    ) async throws {
        let now = Self.now
        try await database.write { db in
            for device in EventRunFixtures.onSiteConvoy(updatedAt: now)
                + EventRunFixtures.depotFleet(updatedAt: now) + extraDevices
            {
                try Device.insert { device }.execute(db)
            }
            for blueprint in blueprints {
                try Blueprint.insert { blueprint }.execute(db)
            }
            try Replicant.insert { EventRunFixtures.courierReplicant() }.execute(db)
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
        let body: @Sendable (OperationKind, String, CommandParams) async -> CommandDispatchResult = { kind, deviceCode, params in
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
        return CommandGovernorClient(
            dispatch: body,
            dispatchOwned: { kind, deviceCode, params, _ in await body(kind, deviceCode, params) }
        )
    }

    /// A catalogue row costed alike for every type, so the ORDER a print lands in
    /// is the only thing the assertions can be reading.
    private func blueprint(_ deviceType: String, components: [String: Int] = [:]) -> Blueprint {
        Blueprint(
            deviceType: deviceType, shortDescription: deviceType, fullDescription: deviceType,
            printTime: 600, features: [], directives: [],
            resources: ResourceCost(structural: 200), stowCapacity: 0, cargoCapacity: 0,
            attachCapacity: 0, queueSize: 0, strength: 1, currentHubs: nil,
            components: components
        )
    }

    /// A printer that really consumes: each accepted print eats its blueprint's
    /// components off the depot floor and stands the result up wearing the tags
    /// it was ordered with. Netting is only meaningful against a printer like this.
    private func printingGovernor(
        _ database: any DatabaseWriter, into printed: LockIsolated<[String]>,
        consuming components: [String: [String: Int]] = [:]
    ) -> CommandGovernorClient {
        let body: @Sendable (OperationKind, String, CommandParams) async -> CommandDispatchResult = { kind, _, params in
            guard kind == .print, let deviceType = params.deviceType else {
                return .dispatched(.accepted(operationID: nil))
            }
            let quantity = params.quantity ?? 1
            printed.withValue { $0.append(deviceType) }
            try? await database.write { db in
                let standing = try Device.all.fetchAll(db).filter { $0.location == "HUB-1" }
                for (component, each) in (components[deviceType] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    for eaten in standing.filter({ $0.deviceType == component })
                        .prefix(each * quantity)
                    {
                        try Device.delete().where { $0.deviceCode.eq(eaten.deviceCode) }.execute(db)
                    }
                }
                for index in 0..<quantity {
                    try Device.upsert {
                        EventRunFixtures.device(
                            "\(deviceType)-\(index)", type: deviceType, location: "HUB-1",
                            tags: params.printTags ?? [], updatedAt: Self.now
                        )
                    }.execute(db)
                }
            }
            return .dispatched(.accepted(operationID: nil))
        }
        return CommandGovernorClient(
            dispatch: body,
            dispatchOwned: { kind, deviceCode, params, _ in await body(kind, deviceCode, params) }
        )
    }

    // MARK: - Termination

    /// **Required.** A ledger that never satisfies the machine must stall, and the
    /// reads it buys on the way must be countable — one walk per evaluation, none
    /// at all once the row has left `.running`.
    @Test("a permanently unmet event stalls, bounded, rather than polling forever")
    func boundedUnmetProgress() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.confirmingProgress.rawValue,
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
        #expect(row.step == EventRun.Step.confirmingProgress.rawValue)
        #expect(row.stepStartedAt == Self.now, "the poll must not re-stamp the deadline it is accruing")
    }

    // MARK: - Printing the tree

    /// **Required.** The eight-hour park this task exists to end: an option whose
    /// device is printed out of other printed devices must order the components
    /// first and then hand on, rather than queueing a job no printer can start.
    @Test("a component-bearing option prints prerequisites first and reaches the load")
    func componentTreePrintsThenLoads() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.printing.rawValue,
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            blueprints: [
                blueprint(
                    "atmospheric_regulator",
                    components: ["filtration_array": 1, "atmo_processor": 2]
                ),
                blueprint("filtration_array"),
                blueprint("atmo_processor"),
                blueprint(EventPlan.beaconDeviceType),
            ]
        )
        let printed = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.now)
            $0.uuid = .incrementing
            $0.commandGovernor = printingGovernor(
                database, into: printed,
                consuming: ["atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2]]
            )
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            for _ in 0..<5 { await core.evaluateOnce(directiveID: "d1") }
        }

        #expect(printed.value == [
            "atmo_processor", "filtration_array", "atmospheric_regulator",
            EventPlan.beaconDeviceType,
        ], "components before the device consuming them, beacon last, nothing twice")
        let row = try await row(database)
        #expect(row.step == EventRun.Step.loading.rawValue)
        #expect(row.status == .running)
        #expect(row.attentionReason == nil)
    }

    /// The other half of the park: every printer busy, and the step past the
    /// deadline its own queued print times derive. The run must surface rather
    /// than wait out another eight hours.
    @Test("every printer busy past the derived deadline surfaces instead of waiting")
    func busyPrintersStallThroughTheEngine() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.printing.rawValue,
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            blueprints: [
                blueprint(
                    "atmospheric_regulator",
                    components: ["filtration_array": 1, "atmo_processor": 2]
                ),
                blueprint("filtration_array"),
                blueprint("atmo_processor"),
                blueprint(EventPlan.beaconDeviceType),
            ]
        )
        // The clock stays put and the STEP is backdated: advancing `now` past the
        // deadline would age the census out from under the rail as well.
        try await database.write { db in
            for operation in EventRunFixtures.openPrint(on: "PRINTER", now: Self.now).values {
                try GameModels.Operation.insert { operation }.execute(db)
            }
            guard var directive = try Directive.where { $0.id.eq("d1") }.fetchOne(db) else { return }
            directive.stepStartedAt = Self.now
                .addingTimeInterval(-(EventRun.printSlack + 600 + 60))
            try Directive.upsert { directive }.execute(db)
        }
        let printed = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.now)
            $0.uuid = .incrementing
            $0.commandGovernor = printingGovernor(database, into: printed)
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            for _ in 0..<3 { await core.evaluateOnce(directiveID: "d1") }
        }

        #expect(printed.value.isEmpty, "nothing may be ordered at a printer that is already busy")
        let row = try await row(database)
        #expect(row.status == .needsAttention)
        #expect(row.attentionReason == .printBlockedOnComponents)
        #expect(row.step == EventRun.Step.printing.rawValue)
    }

    /// A bench that really queues: an accepted print leaves an OPEN op owned by
    /// the run, so nothing more can be ordered until `finishJob` closes it.
    private func benchGovernor(
        _ database: any DatabaseWriter,
        clock: LockIsolated<Date>,
        into orders: LockIsolated<[Job]>
    ) -> CommandGovernorClient {
        let body: @Sendable (OperationKind, String, CommandParams) async -> CommandDispatchResult = { kind, deviceCode, params in
            guard kind == .print, let deviceType = params.deviceType else {
                return .dispatched(.accepted(operationID: nil))
            }
            let quantity = params.quantity ?? 1
            let stamp = clock.value
            let index = orders.withValue { queued -> Int in
                queued.append(Job(type: deviceType, quantity: quantity, tags: params.printTags ?? []))
                return queued.count - 1
            }
            try? await database.write { db in
                try GameModels.Operation.insert {
                    GameModels.Operation(
                        id: "job-\(index)", entityCode: deviceCode,
                        kind: OperationKind.print.rawValue, status: .active, source: .poll,
                        startedAt: stamp, completesAt: nil, lastConfirmedAt: stamp,
                        detail: .object(["params": .object([
                            "device_type": .string(deviceType),
                            "quantity": .number(Double(quantity)),
                        ])]),
                        directiveID: "d1", step: EventRun.Step.printing.rawValue
                    )
                }.execute(db)
            }
            return .dispatched(.accepted(operationID: "job-\(index)"))
        }
        return CommandGovernorClient(
            dispatch: body,
            dispatchOwned: { kind, deviceCode, params, _ in await body(kind, deviceCode, params) }
        )
    }

    /// One ordered print, as the bench fixture remembers it.
    private struct Job: Sendable {
        let type: String
        let quantity: Int
        let tags: [String]
    }

    /// The bench's other half: close round `round`'s op and stand its clones up
    /// at the depot wearing the tags they were ordered with.
    private func finishJob(
        _ database: any DatabaseWriter, round: Int, job: Job, at stamp: Date
    ) async {
        try? await database.write { db in
            guard var operation = try GameModels.Operation
                .where({ $0.id.eq("job-\(round)") }).fetchOne(db)
            else { return }
            operation.status = .completed
            operation.lastConfirmedAt = stamp
            try GameModels.Operation.upsert { operation }.execute(db)
            for index in 0..<job.quantity {
                try Device.upsert {
                    EventRunFixtures.device(
                        "\(job.type)-\(index)", type: job.type, location: "HUB-1",
                        tags: job.tags, updatedAt: stamp
                    )
                }.execute(db)
            }
        }
    }

    /// **The multi-round shape.** One bench, four sequential jobs: each finishes
    /// inside its own bound while the tree as a whole outlasts that bound three
    /// times over. A run printing perfectly must not surface.
    @Test("a deep tree on one bench prints round after round without stalling")
    func aSequentialTreePrintsPastOneJobsBound() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.printing.rawValue,
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            blueprints: [
                blueprint(
                    "atmospheric_regulator",
                    components: ["filtration_array": 1, "atmo_processor": 2]
                ),
                blueprint("filtration_array"),
                blueprint("atmo_processor"),
                blueprint(EventPlan.beaconDeviceType),
            ]
        )
        let clock = LockIsolated(Self.now)
        let orders = LockIsolated<[Job]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .init { clock.value }
            $0.uuid = .incrementing
            // The real `refreshFootprint` over a scripted census, so the reserve
            // rail stays fed as the clock moves instead of vetoing every round.
            $0.locationsClient.footprint = {
                ["HUB-1": LocationCounts(
                    devices: 2, resources: BrainCeiling.aggregateSpendFloor * 2
                )]
            }
            $0.commandGovernor = benchGovernor(database, clock: clock, into: orders)
        } operation: {
            let core = DirectiveEngineCore(machines: [EventRun()], tick: .seconds(5))
            for round in 0..<4 {
                await core.evaluateOnce(directiveID: "d1")   // orders this round's job
                clock.setValue(clock.value.addingTimeInterval(900))
                await core.evaluateOnce(directiveID: "d1")   // the bench is busy
                clock.setValue(clock.value.addingTimeInterval(900))
                guard orders.value.count == round + 1, let job = orders.value.last else { break }
                await finishJob(database, round: round, job: job, at: clock.value)
            }
            await core.evaluateOnce(directiveID: "d1")
        }

        #expect(orders.value.map(\.type) == [
            "atmo_processor", "filtration_array", "atmospheric_regulator",
            EventPlan.beaconDeviceType,
        ], "one job per round, in tree order, and nothing ordered twice")
        let row = try await row(database)
        #expect(row.step == EventRun.Step.loading.rawValue)
        #expect(row.status == .running)
        #expect(row.attentionReason == nil, "7,200s of real progress is not a blocked print")
    }

    // MARK: - The commit

    /// **Required.** The commit is not idempotent from our side, so the POST must
    /// fire exactly once however many evaluations the tail takes.
    @Test("a met event commits exactly once and finishes")
    func commitsOnce() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, step: EventRun.Step.committing.rawValue,
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
            #expect(committed.step == EventRun.Step.collecting.rawValue)
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
            database, step: EventRun.Step.committing.rawValue,
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
            database, step: EventRun.Step.staging.rawValue,
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
        #expect(row.step == EventRun.Step.confirmingProgress.rawValue)
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
            database, step: EventRun.Step.confirmingProgress.rawValue,
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
