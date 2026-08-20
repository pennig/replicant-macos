//
//  WorldTickTests.swift
//  Replicould — DirectiveEngine
//
//  The point of the whole task: one transaction per tick, however many
//  directives are running — and the per-directive `WorldSnapshot` composed
//  back out of it. `ReadCounter` proves the transaction count, not the log.
//  The tick LOOP that drives every executor from that read is here too.
//

import API
import ConcurrencyExtras
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import GameSession
import GRDB
import Sharing
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

/// Counts transactions actually opened, shared across every reader
/// `wrapping(_:)` produces — a fresh count per call would hide a second
/// transaction opened through a second wrapped instance.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    fileprivate func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func wrapping(_ base: any DatabaseReader) -> any DatabaseReader {
        CountingReader(base: base, counter: self)
    }

    func wrapping(_ base: any DatabaseWriter) -> any DatabaseWriter {
        CountingWriter(base: base, counter: self)
    }
}

/// Forwards every `DatabaseReader` requirement to `base` uncounted except the
/// async `read<T: Sendable>` overload — the one `database.read { db in … }`
/// resolves to under `await`, which is the only entry point `WorldTick.read` calls.
private final class CountingReader: DatabaseReader, @unchecked Sendable {
    let base: any DatabaseReader
    let counter: ReadCounter

    init(base: any DatabaseReader, counter: ReadCounter) {
        self.base = base
        self.counter = counter
    }

    var configuration: Configuration { base.configuration }
    var path: String { base.path }
    func close() throws { try base.close() }
    func interrupt() { base.interrupt() }

    @_disfavoredOverload
    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try base.read(value)
    }

    func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        counter.increment()
        return try await base.read(value)
    }

    func asyncRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
        base.asyncRead(value)
    }

    @_disfavoredOverload
    func unsafeRead<T>(_ value: (Database) throws -> T) throws -> T {
        try base.unsafeRead(value)
    }

    func unsafeRead<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        try await base.unsafeRead(value)
    }

    func asyncUnsafeRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
        base.asyncUnsafeRead(value)
    }

    func unsafeReentrantRead<T>(_ value: (Database) throws -> T) throws -> T {
        try base.unsafeReentrantRead(value)
    }

    func _add<Reducer: ValueReducer>(
        observation: ValueObservation<Reducer>,
        scheduling scheduler: some ValueObservationScheduler,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
        base._add(observation: observation, scheduling: scheduler, onChange: onChange)
    }
}

/// `CountingReader`'s writer half. `defaultDatabase` is a writer, so counting the
/// TICK LOOP's transactions means wrapping one; writes pass through uncounted.
private final class CountingWriter: DatabaseWriter, @unchecked Sendable {
    let base: any DatabaseWriter
    let counter: ReadCounter

    init(base: any DatabaseWriter, counter: ReadCounter) {
        self.base = base
        self.counter = counter
    }

    var configuration: Configuration { base.configuration }
    var path: String { base.path }
    func close() throws { try base.close() }
    func interrupt() { base.interrupt() }

    @_disfavoredOverload
    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try base.read(value)
    }

    func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        counter.increment()
        return try await base.read(value)
    }

    func asyncRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
        base.asyncRead(value)
    }

    @_disfavoredOverload
    func unsafeRead<T>(_ value: (Database) throws -> T) throws -> T {
        try base.unsafeRead(value)
    }

    func unsafeRead<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        try await base.unsafeRead(value)
    }

    func asyncUnsafeRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
        base.asyncUnsafeRead(value)
    }

    func unsafeReentrantRead<T>(_ value: (Database) throws -> T) throws -> T {
        try base.unsafeReentrantRead(value)
    }

    @_disfavoredOverload
    func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) rethrows -> T {
        try base.writeWithoutTransaction(updates)
    }

    func writeWithoutTransaction<T: Sendable>(
        _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
        try await base.writeWithoutTransaction(updates)
    }

    func barrierWriteWithoutTransaction<T>(_ updates: (Database) throws -> T) throws -> T {
        try base.barrierWriteWithoutTransaction(updates)
    }

    func barrierWriteWithoutTransaction<T: Sendable>(
        _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
        try await base.barrierWriteWithoutTransaction(updates)
    }

    func asyncBarrierWriteWithoutTransaction(
        _ updates: @escaping @Sendable (Result<Database, Error>) -> Void
    ) {
        base.asyncBarrierWriteWithoutTransaction(updates)
    }

    func unsafeReentrantWrite<T>(_ updates: (Database) throws -> T) rethrows -> T {
        try base.unsafeReentrantWrite(updates)
    }

    func asyncWriteWithoutTransaction(_ updates: @escaping @Sendable (Database) -> Void) {
        base.asyncWriteWithoutTransaction(updates)
    }

    func spawnConcurrentRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
        base.spawnConcurrentRead(value)
    }

    func _add<Reducer: ValueReducer>(
        observation: ValueObservation<Reducer>,
        scheduling scheduler: some ValueObservationScheduler,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
        base._add(observation: observation, scheduling: scheduler, onChange: onChange)
    }
}

@Suite struct WorldTickReads {
    /// The whole point: one transaction, however many directives are
    /// running. Counting reads is what makes the 22x-per-tick regression
    /// impossible to reintroduce without a red test.
    @Test func opensExactlyOneReadTransaction() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for i in 1...5 {
                try Directive.insert {
                    directiveFixture(id: "D\(i)", deviceCode: "V\(i)", targets: ["SOL"])
                }.execute(db)
            }
        }
        let counter = ReadCounter()
        let tick = try await WorldTick.read(
            from: counter.wrapping(database), now: Date(timeIntervalSince1970: 100), generation: 1
        )
        #expect(tick.running.count == 5)
        #expect(tick.generation == 1)
        #expect(counter.reads == 1)
    }

    /// A non-running directive contributes nothing to `running`, and its
    /// presence must not cost a second transaction.
    @Test func pausedDirectivesAreExcludedAndStillOneTransaction() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D1", deviceCode: "V1", targets: ["SOL"])
            }.execute(db)
            try Directive.insert {
                directiveFixture(id: "D2", status: .paused, deviceCode: "V2", targets: ["SOL"])
            }.execute(db)
        }
        let counter = ReadCounter()
        let tick = try await WorldTick.read(
            from: counter.wrapping(database), now: Date(timeIntervalSince1970: 100), generation: 1
        )
        #expect(tick.running.map(\.id) == ["D1"])
        #expect(counter.reads == 1)
    }
}

@Suite struct WorldTickComposition {
    /// A running directive's `snapshot(for:)` composes real content — not an
    /// empty snapshot that would pass on a bare dictionary key. A paused
    /// sibling, sharing the same target, gets none.
    @Test func composesASnapshotPerRunningDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D1", deviceCode: "V1", targets: ["SOL"])
            }.execute(db)
            try Directive.insert {
                directiveFixture(id: "D2", status: .paused, deviceCode: "V2", targets: ["SOL"])
            }.execute(db)
            try seedSystemDetail(db, system: "SOL", scanned: true)
            try seedSalvageAssay(db, id: "SITE-SOL", system: "SOL", totals: ["metal": 100])
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                    summary: "started", step: nil, operationID: nil, eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
        }
        let tick = try await WorldTick.read(
            from: database, now: Date(timeIntervalSince1970: 100), generation: 1
        )
        let snapshot = try #require(tick.snapshot(for: "D1"))
        #expect(!snapshot.systems.isEmpty)
        #expect(!snapshot.siteAssays.isEmpty)
        #expect(!snapshot.log.isEmpty)
        #expect(snapshot.now == Date(timeIntervalSince1970: 100))
        #expect(tick.snapshot(for: "D2") == nil)
    }

    /// A directive absent from the roster entirely — never inserted, never
    /// running — is indistinguishable from a paused one: no slice, no snapshot.
    @Test func unknownDirectiveIDHasNoSnapshot() async throws {
        let database = try GameDatabase.bootstrap()
        let tick = try await WorldTick.read(
            from: database, now: Date(timeIntervalSince1970: 100), generation: 1
        )
        #expect(tick.snapshot(for: "GHOST") == nil)
    }
}

@Suite struct WorldViewFromCore {
    /// The brain's view and the directives' core must be the same world. Built
    /// from one read, they cannot disagree; built from two, they routinely did.
    @Test func matchesTheStandaloneRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert {
                Device(
                    deviceCode: "V1", deviceType: "transport_hauler", replicantCode: "R1",
                    status: "idle", location: "SOL-3", locationName: nil,
                    operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
                    controllerDeviceCode: nil, attachedToDeviceCode: nil,
                    createdAt: Date(timeIntervalSince1970: 0), availableCommands: ["enqueue_print"],
                    features: [], tags: [], detail: .object([:]),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    firstSeenAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
            try LocationFootprint.insert {
                LocationFootprint(
                    location: "SOL-3", devices: 1, resources: 500, resourceSites: 0,
                    locationEvents: 0, replicants: 0,
                    fetchedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
            try seedRelay(db, code: "REL1", location: "SOL-3")
            try TheatrePin.insert {
                TheatrePin(location: "SOL-3", createdAt: Date(timeIntervalSince1970: 0))
            }.execute(db)
            try Blueprint.insert {
                Blueprint(
                    deviceType: "transport_hauler", shortDescription: "", fullDescription: "",
                    printTime: 600, features: [], directives: [],
                    resources: ResourceCost(structural: 200), stowCapacity: 0, cargoCapacity: 0,
                    attachCapacity: 0, queueSize: 0, strength: 1, currentHubs: nil,
                    components: ["module_x": 1]
                )
            }.execute(db)
            // Three, out of designation order, so the equivalence catches a
            // sort that only happens to agree on a one-row fixture.
            try seedLocationEvent(db, designation: "EVT3", location: "SOL-3")
            try seedLocationEvent(db, designation: "EVT1", location: "SOL-3")
            try seedLocationEvent(db, designation: "EVT2", location: "SOL-3")
            try seedReplicant(db, code: "REP1", star: "SOL", hostedDeviceCode: "V1")
            try seedSalvageAssay(db, id: "SITE-SOL", system: "SOL", totals: ["metal": 100])
            try TheatreRecord.insert {
                TheatreRecord(
                    depot: "SOL-3", system: "SOL", origin: "pinned",
                    establishedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
            try seedSystemDetail(
                db, system: "SOL", scanned: true,
                belts: [Belt(designation: "SOL-1-BELT", density: "dense")]
            )
            // The pin is now operational (print-capable, stocked, meshed),
            // which is what makes `LocationInventory` scope to it.
            try LocationInventory.insert {
                LocationInventory(
                    location: "SOL-3", resourceType: "metal", quantity: 250,
                    fetchedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
        }

        let now = Date(timeIntervalSince1970: 100)
        let (fromCore, standalone) = try await database.read { db in
            (
                try WorldView.read(from: db, core: try WorldCore.read(from: db), now: now),
                try WorldView.read(from: db, now: now)
            )
        }
        #expect(fromCore == standalone)

        #expect(!fromCore.devices.isEmpty)
        #expect(!fromCore.starPositions.isEmpty)
        #expect(!fromCore.meshSystems.isEmpty)
        #expect(!fromCore.salvageUnits.isEmpty)
        #expect(!fromCore.eventSystems.isEmpty)
        #expect(!fromCore.theatres.isEmpty)
        #expect(!fromCore.theatreRecords.isEmpty)
        #expect(!fromCore.components.isEmpty)
        #expect(!fromCore.beltsBySystem.isEmpty)
        #expect(!fromCore.surveyedSystems.isEmpty)
        #expect(!fromCore.replicantSystems.isEmpty)
        #expect(!fromCore.replicantHostDevices.isEmpty)
        #expect(!fromCore.stockpileUnits.isEmpty)
        #expect(!fromCore.theatreStock.isEmpty)
        #expect(fromCore.theatreStockFreshness != nil)
        #expect(fromCore.locationEvents.count == 3)
        #expect(!fromCore.blueprintBills.isEmpty)
        #expect(!fromCore.blueprintComponents.isEmpty)
    }
}

// MARK: - The tick loop

/// Advances every directive it is asked about, recording the ids.
private struct StepAdvancingMachine: MissionStepMachine {
    let kind: DirectiveKind = .salvageRun
    let firstStep = "step"
    let asked = LockIsolated<[String]>([])

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        asked.withValue { $0.append(directive.id) }
        return .advanceStep(nextStep: "advanced")
    }

    func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}

/// `D1` asks for a device refresh the harness answers on its own schedule;
/// every other directive advances. Records the ids it was asked about, which is
/// what a would-be second evaluation of `D1` shows up in.
private struct BlockingMachine: MissionStepMachine {
    let kind: DirectiveKind = .salvageRun
    let firstStep = "step"
    let asked = LockIsolated<[String]>([])

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        asked.withValue { $0.append(directive.id) }
        return directive.id == "D1"
            ? .refreshDevices(deviceCodes: ["V1"], thenStall: nil)
            : .advanceStep(nextStep: "advanced")
    }

    func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}

/// Waits, recording the ids it was asked about. `.wait` writes no row, so a
/// transaction count taken around it is the LOOP's and nothing else's.
private struct WaitingMachine: MissionStepMachine {
    let kind: DirectiveKind = .salvageRun
    let firstStep = "step"
    let asked = LockIsolated<Set<String>>([])

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        asked.withValue { $0.insert(directive.id) }
        return .wait
    }

    func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}

/// `GameClient.testValue` with a budget read that blocks until released — the
/// first thing `Brain.report` awaits that a test can hold open.
private func gatedGameClient(_ released: LockIsolated<Bool>) -> GameClient {
    var client = GameClient.testValue
    client.budget = { _ in
        while !released.value { await Task.yield() }
        return RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil)
    }
    return client
}

/// The why-view's feed as it stands right now, re-read each call — a captured
/// `@Shared` cannot cross into the `@Sendable` closures below.
@Sendable private func publishedReport() -> BrainReport? {
    @Shared(.brainReport) var report: BrainReport?
    return report
}

/// Start `runTick` off-thread and wait for it to RETURN, with a deadline. A tick
/// that waited on a hung brain would otherwise hang the suite rather than fail;
/// the returned task must be awaited once the hang is released.
private func boundedTick(
    _ core: DirectiveEngineCore, generation: UInt64,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Task<Void, Never> {
    let returned = LockIsolated(false)
    let task = Task { await core.runTick(generation: generation); returned.setValue(true) }
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, !returned.value { await Task.yield() }
    if !returned.value {
        Issue.record("runTick did not return — it is waiting on the brain", sourceLocation: sourceLocation)
    }
    return task
}

/// Poll `condition` on the real clock: an executor's evaluation is a genuine
/// cross-thread hop, so a fixed yield count would flake.
private func settle(
    _ condition: @Sendable () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        await Task.yield()
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}

private func steps(_ database: any DatabaseReader) async throws -> [String] {
    try await database.read { db in try Directive.all.order { $0.id }.fetchAll(db) }.map(\.step)
}

@Suite struct TickLoopTests {
    /// One tick reconciles the roster and evaluates EVERY running directive
    /// from its own single read — no executor opens a read of its own.
    @Test func oneTickAdvancesEveryRunningDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for i in 1...3 {
                try Directive.insert {
                    directiveFixture(id: "D\(i)", deviceCode: "V\(i)", targets: ["SOL"])
                }.execute(db)
            }
        }
        let machine = StepAdvancingMachine()
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            await core.runTick(generation: 1)
            try await settle { try await steps(database) == ["advanced", "advanced", "advanced"] }
            #expect(await core.executorCount == 3, "one executor per running directive")
            #expect(machine.asked.value.sorted() == ["D1", "D2", "D3"])
            await core.stop()
        }
    }

    /// The brain runs off the SAME tick, and its report reaches the why-view's
    /// feed — one tick loop, not a supervisor with a brain beside it.
    @Test func oneTickAlsoTicksTheBrain() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedRelay(db, code: "REL1", location: "SOL")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
        }
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            await core.runTick(generation: 1)
            // The brain runs BESIDE the executors now, so settle on its report
            // rather than assuming it finished before `runTick` returned.
            try await settle { publishedReport() != nil }
            #expect(await core.brainTickCount == 1)
            #expect(
                publishedReport()?.observedAt == Date(timeIntervalSince1970: 100),
                "the report is stamped with the tick's own instant"
            )
            await core.stop()
            #expect(publishedReport() == nil, "stop() retires the feed with the loop that fed it")
        }
    }

    /// Error isolation and serialisation in one: a directive blocked in a
    /// refresh neither delays its siblings' evaluations nor takes a second
    /// evaluation of its own while the first is still in flight.
    @Test func aBlockedDirectiveNeitherDelaysSiblingsNorDoublesUp() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for i in 1...3 {
                try Directive.insert {
                    directiveFixture(id: "D\(i)", deviceCode: "V\(i)", targets: ["SOL"])
                }.execute(db)
            }
        }
        let entered = LockIsolated(0)
        let released = LockIsolated(false)
        let machine = BlockingMachine()
        @Sendable func asks(_ id: String) -> Int { machine.asked.value.filter { $0 == id }.count }
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.defaultInMemoryStorage = InMemoryStorage()
            $0.deviceRefresher = DeviceRefreshClient { _, _ in
                entered.withValue { $0 += 1 }
                while !released.value { await Task.yield() }
                return nil
            }
        } operation: {
            await core.runTick(generation: 1)
            try await settle { try await steps(database) == ["step", "advanced", "advanced"] }
            #expect(entered.value == 1, "D1 is blocked in its refresh")

            await core.runTick(generation: 2)
            await core.runTick(generation: 3)
            // The barrier is a POSITIVE signal: wait until both siblings have
            // consumed a delivery made AFTER D1 blocked, not for an old truth.
            try await settle { asks("D2") > 1 && asks("D3") > 1 }
            #expect(asks("D1") == 1, "a tick landing mid-evaluation must not start a second")
            #expect(entered.value == 1, "and must not re-enter the refresh")
            #expect(try await steps(database) == ["step", "advanced", "advanced"])

            released.setValue(true)
            await core.stop()
        }
    }

    /// The brain reaches the network, so it must not sit in front of the
    /// executors: a `report()` that never returns leaves every directive
    /// evaluating, and the next tick skips the brain rather than queueing one.
    @Test func aHungBrainStallsNeitherTheExecutorsNorTheNextTick() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for i in 1...3 {
                try Directive.insert {
                    directiveFixture(id: "D\(i)", deviceCode: "V\(i)", targets: ["SOL"])
                }.execute(db)
            }
        }
        let released = LockIsolated(false)
        let machine = StepAdvancingMachine()
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.defaultInMemoryStorage = InMemoryStorage()
            $0.gameClient = gatedGameClient(released)
        } operation: {
            let first = await boundedTick(core, generation: 1)
            try await settle { try await steps(database) == ["advanced", "advanced", "advanced"] }
            #expect(await core.brainTickCount == 1, "the brain started, and is still hung")

            let second = await boundedTick(core, generation: 2)
            try await settle { machine.asked.value.count > 3 }
            #expect(
                await core.brainTickCount == 1,
                "a tick landing on an unfinished brain skips it rather than queueing one"
            )
            #expect(publishedReport() == nil, "nothing published while report() is hung")

            released.setValue(true)
            try await settle { publishedReport() != nil }
            _ = await first.value
            _ = await second.value
            await core.stop()
        }
    }

    /// Pinned on the LOOP rather than on `WorldTick.read` alone: a tick's
    /// transaction count is a constant, whatever the roster size — a per-directive
    /// read would make it scale, which is exactly what this catches.
    @Test func aTicksTransactionCountDoesNotGrowWithTheRoster() async throws {
        let small = try await tickReads(directives: 2)
        let large = try await tickReads(directives: 8)
        #expect(small == large, "reads must be a constant, not one per directive")
        #expect(large <= 3, "the tick's own read, and the brain's — never a per-directive one")
    }

    /// Transactions opened by ONE `runTick` over `directives` running directives,
    /// counted after every executor has evaluated and the brain has published —
    /// so nothing of the tick is still outstanding when the count is read.
    private func tickReads(directives: Int) async throws -> Int {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for i in 1...directives {
                try Directive.insert {
                    directiveFixture(id: "D\(i)", deviceCode: "V\(i)", targets: ["SOL"])
                }.execute(db)
            }
        }
        let counter = ReadCounter()
        let machine = WaitingMachine()
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))
        return try await withDependencies {
            $0.defaultDatabase = counter.wrapping(database)
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            await core.runTick(generation: 1)
            try await settle {
                machine.asked.value.count == directives && publishedReport() != nil
            }
            await core.stop()
            return counter.reads
        }
    }
}

@Suite struct PausedDirectiveDelta {
    /// The one accepted behaviour change, pinned rather than left to inspection:
    /// the directive row comes from the tick's read, so a pause landing mid-tick
    /// is honoured on the NEXT tick, up to 5s later.
    @Test func advancesNoDirectivePausedBeforeTheTickRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D1", status: .paused, deviceCode: "V1", targets: ["SOL"])
            }.execute(db)
        }
        let tick = try await WorldTick.read(
            from: database, now: Date(timeIntervalSince1970: 100), generation: 1
        )
        #expect(tick.running.isEmpty)
        #expect(tick.snapshot(for: "D1") == nil)
    }

    /// The delta itself, both halves: a pause landing AFTER the tick's read is
    /// still evaluated against that read, and the very next tick honours it.
    @Test func aPauseLandingAfterTheReadIsHonouredOnTheNextTick() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D1", deviceCode: "V1", targets: ["SOL"])
            }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 100)
        let first = try await WorldTick.read(from: database, now: now, generation: 1)
        try await database.write { db in
            try Directive.where { $0.id.eq("D1") }
                .update { $0.status = DirectiveStatus.paused }
                .execute(db)
        }
        let core = DirectiveEngineCore(machines: [StepAdvancingMachine()], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1", tick: first)
            #expect(try await steps(database) == ["advanced"], "the tick's row is what it evaluated")

            // That evaluation's whole-row write put `running` back, so re-pause
            // exactly as the operator would before the next tick reads.
            try await database.write { db in
                try Directive.where { $0.id.eq("D1") }
                    .update { $0.status = DirectiveStatus.paused }
                    .execute(db)
            }
            let second = try await WorldTick.read(from: database, now: now, generation: 2)
            #expect(second.running.isEmpty)
            await core.evaluateOnce(directiveID: "D1", tick: second)
            let row = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(row?.status == .paused, "a paused row is never advanced once the tick has seen it")
            #expect(row?.step == "advanced", "and never advanced a second time")
        }
    }
}
