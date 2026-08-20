//
//  WorldTickTests.swift
//  Replicould — DirectiveEngine
//
//  The point of the whole task: one transaction per tick, however many
//  directives are running — and the per-directive `WorldSnapshot` composed
//  back out of it. `ReadCounter` proves the transaction count, not the log.
//

import Foundation
import GameDatabase
import GameModels
import GRDB
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
