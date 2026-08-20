//
//  WorldSnapshotTests.swift
//  Replicould — DirectiveEngine
//
//  The read-only view of reconciled state a step machine reasons over. Built
//  from SQLite, never from raw events — that invariant is what makes missions
//  replay-immune and loop-proof.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private typealias Operation = GameModels.Operation

private func device(_ code: String, updatedAt: Date = Date(timeIntervalSince1970: 0)) -> Device {
    Device(
        deviceCode: code, deviceType: "transport_hauler", replicantCode: "R1",
        status: "idle", location: "SOL-3", locationName: nil, operationalCapacity: 100,
        queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: [], tags: [], detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func op(
    _ id: String, device: String, status: OperationStatus, directiveID: String? = nil,
    startedAt: Date = Date(timeIntervalSince1970: 0)
) -> Operation {
    Operation(
        id: id, entityCode: device, kind: OperationKind.travel.rawValue,
        status: status, source: OperationSource.optimistic,
        startedAt: startedAt, completesAt: nil,
        lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:]),
        directiveID: directiveID
    )
}

/// A `D1`-owned `.stepStarted` entry stamped `i` seconds after the epoch, id
/// `"L<i>"` — the window-truncation tests' filler row.
private func worldSnapshotTestLogEntry(_ i: Int) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L\(i)", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
        summary: "step \(i)", step: nil, operationID: nil, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: Double(i))
    )
}

private func directive(targets: [String] = ["SOL"]) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        targets: targets, targetIndex: 0, step: "preflight",
        stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("WorldSnapshot")
struct WorldSnapshotTests {
    /// The snapshot carries THIS directive's log entries and no one else's —
    /// completion detection keys off them, so a neighbouring mission's timeline
    /// must never be mistaken for this one's.
    @Test func loadsOnlyThisDirectivesLogEntries() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .directiveCompleted,
                    summary: "mine", step: nil, operationID: nil, eventID: "E1",
                    occurredAt: Date(timeIntervalSince1970: 10)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L2", directiveID: "D2", deviceCode: nil, kind: .directiveCompleted,
                    summary: "someone else's", step: nil, operationID: nil, eventID: "E2",
                    occurredAt: Date(timeIntervalSince1970: 11)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.log.map(\.id) == ["L1"])
    }

    /// A directive whose history exceeds `logWindow` still gets a snapshot: the
    /// newest `logWindow` entries, oldest first — the order every re-entry
    /// walk-back (`HaulRun.dispatchAttemptCount` and friends) already assumes.
    @Test func truncatesToTheNewestLogWindowEntriesInAscendingOrder() async throws {
        let database = try GameDatabase.bootstrap()
        let total = WorldSnapshot.logWindow + 50
        try await database.write { db in
            for i in 0..<total {
                try DirectiveLogEntry.insert { worldSnapshotTestLogEntry(i) }.execute(db)
            }
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 10_000), directive: directive()
        )
        #expect(world.log.count == WorldSnapshot.logWindow)
        #expect(world.log.first?.id == "L50")
        #expect(world.log.last?.id == "L\(total - 1)")
        #expect(world.log.map(\.occurredAt) == world.log.map(\.occurredAt).sorted())
    }

    /// A directive under the window is untouched — truncation only ever bites
    /// once the history outgrows `logWindow`.
    @Test func leavesALogUnderTheWindowUnaffected() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for i in 0..<10 {
                try DirectiveLogEntry.insert { worldSnapshotTestLogEntry(i) }.execute(db)
            }
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 1_000), directive: directive()
        )
        #expect(world.log.map(\.id) == (0..<10).map { "L\($0)" })
    }

    /// Cached system blobs are decoded for the directive's targets, so the
    /// machine can read scan counts without any I/O of its own.
    @Test func decodesCachedSystemsForTheTargets() async throws {
        let database = try GameDatabase.bootstrap()
        let system = StarSystem(designation: "SOL", planetsScanned: 3, planetsTotal: 3)
        let row = try SystemDetail(system: system, hydratedAt: Date(timeIntervalSince1970: 0))
        try await database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.system("SOL")?.planetsScanned == 3)
        #expect(world.system("NOPE") == nil)
    }

    /// Only the CURRENT target's blob is decoded, never a later one on the
    /// tour. A roaming run's target list grows without bound, and every reader
    /// of `systems` asks about `currentTarget`.
    @Test func decodesOnlyTheCurrentTargetsBlob() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for designation in ["SOL", "VEGA", "RIGEL"] {
                let row = try SystemDetail(
                    system: StarSystem(designation: designation, planetsScanned: 1, planetsTotal: 4),
                    hydratedAt: Date(timeIntervalSince1970: 0)
                )
                try SystemDetail.upsert { row }.execute(db)
            }
        }

        var touring = directive(targets: ["SOL", "VEGA", "RIGEL"])
        touring.targetIndex = 1

        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: touring
        )

        #expect(world.system("VEGA")?.planetsTotal == 4)
        #expect(world.system("SOL") == nil)
        #expect(world.system("RIGEL") == nil)
        #expect(world.systems.count == 1)
    }

    /// The origin and the vessel's current system are decoded alongside the
    /// current target — the return leg and the arrival check read them.
    @Test func decodesTheOriginAndTheVesselsOwnSystem() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for designation in ["SOL", "VEGA", "RIGEL"] {
                let row = try SystemDetail(
                    system: StarSystem(designation: designation, planetsScanned: 1, planetsTotal: 4),
                    hydratedAt: Date(timeIntervalSince1970: 0)
                )
                try SystemDetail.upsert { row }.execute(db)
            }
            try Device.upsert { device("VES1") }.execute(db)
        }

        var touring = directive(targets: ["VEGA", "ALTAIR"])
        touring.originDesignation = "RIGEL"

        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: touring
        )

        // `device(_:)` places VES1 at SOL-3, so SOL is the vessel's system.
        #expect(world.system("VEGA") != nil)
        #expect(world.system("RIGEL") != nil)
        #expect(world.system("SOL") != nil)
    }

    /// A system the directive doesn't name isn't decoded — the catalogue runs
    /// to thousands of bodies and decoding all of it per tick would be real cost.
    @Test func doesNotDecodeUnrelatedSystems() async throws {
        let database = try GameDatabase.bootstrap()
        let row = try SystemDetail(
            system: StarSystem(designation: "FARAWAY"),
            hydratedAt: Date(timeIntervalSince1970: 0)
        )
        try await database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.systems.isEmpty)
    }

    /// Devices are keyed for O(1) lookup and `world.now` is the read's clock;
    /// a CLOSED op is absent from both `openOperation` and `queuedOperations`.
    @Test func readsDevicesAndDropsClosedOperations() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { device("VES1") }.execute(db)
            try Device.insert { device("AMI1") }.execute(db)
            try Operation.insert { op("OP1", device: "VES1", status: .active) }.execute(db)
            try Operation.insert { op("OP2", device: "AMI1", status: .completed) }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 5_000)
        let world = try await WorldSnapshot.read(from: database, now: now, directive: directive())

        #expect(world.devices.keys.sorted() == ["AMI1", "VES1"])
        #expect(world.device("VES1")?.deviceCode == "VES1")
        #expect(world.openOperation(for: "AMI1") == nil)
        #expect(world.queuedOperations["AMI1"] == nil)
        #expect(world.now == now)
    }

    /// The active op is the only one `openOperation` sees; a queued sibling on
    /// the SAME device shows only through `queuedOperations` — the narrowing
    /// this ticket makes, proved by a device carrying both at once.
    @Test("the active op is keyed per device; queued ops are not")
    func activeOpIsKeyedPerDevice() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { op("OP-1", device: "B1", status: .active) }.execute(db)
            try Operation.insert {
                op("OP-2", device: "B1", status: .enqueued, startedAt: Date(timeIntervalSince1970: 1))
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )

        #expect(world.openOperation(for: "B1")?.id == "OP-1")
        #expect(world.queuedOperations["B1"]?.map(\.id) == ["OP-1", "OP-2"])
    }

    /// A bench with nothing on the platen but jobs waiting has no active op.
    @Test("a bench with only queued jobs has no active op")
    func queuedOnlyHasNoActiveOp() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { op("OP-2", device: "B1", status: .enqueued) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )

        #expect(world.openOperation(for: "B1") == nil)
        #expect(world.queuedOperations["B1"]?.count == 1)
    }

    /// A bench's live ops come back oldest first, not insertion order — the
    /// invariant a "pick the oldest matching op" completion rule and a
    /// "position = index" queue-depth read both depend on.
    @Test func queuedOpsAreOldestFirst() {
        let older = op("OP-1", device: "B1", status: .active, startedAt: Date(timeIntervalSince1970: -120))
        let newer = op("OP-2", device: "B1", status: .active, startedAt: Date(timeIntervalSince1970: -60))
        let world = WorldSnapshot(
            devices: [:], openOperations: [:],
            queuedOperations: ["B1": [newer, older]],
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(world.queuedOperations["B1"]?.map(\.id) == ["OP-1", "OP-2"])
    }

    /// `startedAt` is a client clock stamped at dispatch, and two ops written
    /// in one transaction can share it — `id` breaks the tie so the order
    /// stays stable across reads.
    @Test func queuedOpsTieBreakOnIDWhenStartedAtTies() {
        let shared = Date(timeIntervalSince1970: 0)
        let opA = op("OP-A", device: "B1", status: .active, startedAt: shared)
        let opB = op("OP-B", device: "B1", status: .active, startedAt: shared)
        let world = WorldSnapshot(
            devices: [:], openOperations: [:],
            queuedOperations: ["B1": [opB, opA]],
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(world.queuedOperations["B1"]?.map(\.id) == ["OP-A", "OP-B"])
    }

    /// An optimistic op is staged, not active: `openOperation` never returns
    /// it, though `queuedOperations` carries it.
    @Test func optimisticOpsDoNotCountAsActive() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { device("VES1") }.execute(db)
            try Operation.insert { op("OP1", device: "VES1", status: .optimistic) }.execute(db)
        }
        let world = try await WorldSnapshot.read(from: database, now: Date(timeIntervalSince1970: 0), directive: directive())
        #expect(world.openOperation(for: "VES1") == nil)
        #expect(world.queuedOperations["VES1"]?.map(\.id) == ["OP1"])
    }

    /// A mission asking "is MY op open" must not read a co-tenant's job on the
    /// same device as its own — the defect `RestockRun`/`EventCourierPrint`
    /// still carry. A nil owner keeps `openOperation(for:)`'s old meaning.
    @Test func openOperationWithOwnerFiltersByDirective() {
        let world = WorldSnapshot(
            devices: ["PRINTER": device("PRINTER")],
            openOperations: ["PRINTER": op("OP1", device: "PRINTER", status: .active, directiveID: "OTHER")],
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(world.openOperation(for: "PRINTER", owner: "MINE") == nil)
        #expect(world.openOperation(for: "PRINTER", owner: "OTHER") != nil)
        #expect(world.openOperation(for: "PRINTER", owner: nil) != nil)
    }

    /// The one freshness predicate missions use from now on: a strict watermark
    /// compare, nothing more.
    @Test func isFreshComparesUpdatedAtToWatermark() {
        let watermark = Date(timeIntervalSince1970: 1_000)
        let world = WorldSnapshot(devices: [:], openOperations: [:], now: watermark)
        let stale = device("D1", updatedAt: watermark.addingTimeInterval(-1))
        let fresh = device("D1", updatedAt: watermark)
        #expect(world.isFresh(stale, since: watermark) == false)
        #expect(world.isFresh(fresh, since: watermark) == true)
    }

    /// A dispatch carrying no `operationID` never reaches `auditLog`.
    /// `recordCompletedOps` rejects one on its first guard — a `.simple` verb
    /// creates no `Operation` — and on a long-lived roaming run those entries
    /// outnumber the resolvable ones several times over.
    @Test func auditLogDropsDispatchesThatNameNoOperation() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L-SIMPLE", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
                    summary: "stow", step: nil, operationID: nil, eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L-TRACKED", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
                    summary: "travel", step: nil, operationID: "OP1", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 2)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L-DONE", directiveID: "D1", deviceCode: nil, kind: .opCompleted,
                    summary: "travel completed", step: nil, operationID: "OP1", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 3)
                )
            }.execute(db)
        }

        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )

        #expect(world.auditLog.map(\.id) == ["L-TRACKED", "L-DONE"])
    }

    /// `dispatchedOperations` reads `operations.directiveID` first, union the
    /// legacy log join — a row from before that column existed is found only
    /// through its own `.commandDispatched` entry.
    @Test func dispatchedOperationsReadsTheOwnerColumn() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { device("VES1") }.execute(db)
            try Operation.insert {
                op("OP-OWNED", device: "VES1", status: .completed, directiveID: "D1")
            }.execute(db)
            try Operation.insert {
                op("OP-LEGACY", device: "VES1", status: .completed)
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
                    summary: "dispatched", step: nil, operationID: "OP-LEGACY", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.dispatchedOperations.keys.sorted() == ["OP-LEGACY", "OP-OWNED"])
    }

    /// An empty database is a valid snapshot, not an error — the engine starts
    /// before the fleet has cold-loaded.
    @Test func emptyDatabaseYieldsAnEmptySnapshot() async throws {
        let database = try GameDatabase.bootstrap()
        let world = try await WorldSnapshot.read(from: database, now: Date(timeIntervalSince1970: 1), directive: directive())
        #expect(world.devices.isEmpty)
        #expect(world.openOperations.isEmpty)
    }

    /// Assay totals are read for the directive's targets, keyed by SITE
    /// designation — the shape `StarSystem.salvageBodies(totals:)` expects —
    /// so a mission can rank salvage bodies by assayed units rather than
    /// degrading silently to alphabetical order.
    @Test func loadsSiteAssaysForTheTargets() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try SiteAssay.insert {
                SiteAssay(
                    id: "SOL-3-SAL-1", body: "SOL-3", system: "SOL", siteType: "salvage",
                    totals: ["ore": 500], assayedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.siteAssays == ["SOL-3-SAL-1": ["ore": 500]])
    }

    /// An assay belonging to a system the directive doesn't name is never
    /// loaded — the same "only the wanted set" scoping as the `StarSystem`
    /// blobs, never the whole table.
    @Test func doesNotLoadSiteAssaysForUnrelatedSystems() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try SiteAssay.insert {
                SiteAssay(
                    id: "FARAWAY-2-SAL-1", body: "FARAWAY-2", system: "FARAWAY", siteType: "salvage",
                    totals: ["ore": 500], assayedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.siteAssays.isEmpty)
    }
}

@Suite("WorldSnapshot footprints")
struct WorldSnapshotFootprintTests {

    private func footprint(_ location: String, resources: Int, at fetchedAt: Date) -> LocationFootprint {
        LocationFootprint(
            location: location, devices: 0, resources: resources, resourceSites: 0,
            locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
        )
    }

    private func directive() -> Directive {
        Directive(
            id: "D1", kind: .haulRun, status: .running, deviceCode: "CTRL1",
            targets: [], targetIndex: 0, step: "preflight",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// The whole table comes back, keyed by designation — the planner ranks
    /// across every known location, so any scoping here would hide candidates.
    @Test func everyFootprintRowIsReadAndKeyedByLocation() async throws {
        let database = try GameDatabase.bootstrap()
        let stamp = Date(timeIntervalSince1970: 500)
        try await database.write { db in
            try LocationFootprint.insert {
                footprint("ATIANFU-BELT-1", resources: 3_537, at: stamp)
                footprint("AINALRAM-BELT-1", resources: 59_230, at: stamp)
                footprint("SOL-BELT-1", resources: 0, at: stamp)
            }.execute(db)
        }

        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 1_000), directive: directive()
        )

        #expect(world.footprints.count == 3)
        #expect(world.footprints["ATIANFU-BELT-1"]?.resources == 3_537)
        #expect(world.footprints["SOL-BELT-1"]?.resources == 0)
        #expect(world.footprints["ATIANFU-BELT-1"]?.fetchedAt == stamp)
    }

    /// An empty table is a legitimate cold-start state, not an error — the run
    /// refreshes into it rather than stalling.
    @Test func anEmptyTableReadsAsNoFootprints() async throws {
        let database = try GameDatabase.bootstrap()
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 1_000), directive: directive()
        )
        #expect(world.footprints.isEmpty)
    }
}

@Suite("WorldSnapshot star positions")
struct WorldSnapshotStarPositionTests {

    private func directive() -> Directive {
        Directive(
            id: "D1", kind: .haulRun, status: .running, deviceCode: "CTRL1",
            targets: [], targetIndex: 0, step: "preflight",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Every axis distinct, so a transposed column mapping cannot read as
    /// correct. `read` projects four columns rather than decoding the row, and
    /// that projection is positional — a symmetric fixture defends nothing.
    @Test func eachAxisIsCarriedSeparately() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedStar(db, designation: "ASYM", x: 1, y: 2, z: 3)
            try seedStar(db, designation: "NEG", x: -7.5, y: 0.25, z: -0.5)
        }

        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 1_000), directive: directive()
        )

        #expect(world.starPositions["ASYM"] == Position(x: 1, y: 2, z: 3))
        #expect(world.starPositions["NEG"] == Position(x: -7.5, y: 0.25, z: -0.5))
    }
}

@Suite("WorldSnapshot events")
struct WorldSnapshotEventTests {
    @Test("the snapshot reads the whole event ledger")
    func readsEvents() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_000)
        try await database.write { db in
            try LocationEvent.insert {
                LocationEvent(
                    designation: "X-1-EVT-001", location: "X-1", status: "active",
                    firstSeenAt: now, updatedAt: now
                )
            }.execute(db)
            try LocationEvent.insert {
                LocationEvent(
                    designation: "Y-2-EVT-001", location: "Y-2", status: "completed",
                    firstSeenAt: now, updatedAt: now
                )
            }.execute(db)
        }
        let directive = Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
            targets: ["X-1-EVT-001"], targetIndex: 0, step: "preflight",
            stepStartedAt: now, returnToOrigin: true, originDesignation: nil,
            attentionReason: nil, createdAt: now, updatedAt: now
        )
        let world = try await WorldSnapshot.read(from: database, now: now, directive: directive)
        #expect(world.locationEvents.count == 2)
        #expect(world.event("X-1-EVT-001")?.location == "X-1")
        #expect(world.event("MISSING") == nil)
    }
}
