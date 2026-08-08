//
//  BrainSalvageTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.salvageReadiness` as a pure function table: every gate names why it
//  declined, an unstaged fleet idles rather than manufacturing a stall, and
//  unmeshed salvage is not this goal's to reach.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let salvageFixtureNow = Date(timeIntervalSince1970: 5_000)

/// A device for the readiness fixtures. `directives:` feeds
/// `available_directives`, which is what `AMIFleet.stowed(offering:)` reads.
private func salvageDevice(
    _ code: String,
    type: String,
    tags: [String] = [],
    stowedIn: String? = nil,
    controllerDeviceCode: String? = nil,
    directives: [String] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
        location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: [], tags: tags, detail: .object(detail),
        updatedAt: salvageFixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A fully staged salvage vessel: tagged, a mining controller stowed aboard
/// offering `gather_salvage`, and one drone that controller has adopted.
private func salvageStagedFleet(carrier: String = "V1") -> [Device] {
    [
        salvageDevice(carrier, type: Brain.carrierDeviceType, tags: [Brain.salvageCarrierTag]),
        salvageDevice(
            "AMI1", type: "ami_mining_controller", stowedIn: carrier, directives: ["gather_salvage"]
        ),
        salvageDevice("DRONE1", type: "mining_drone", stowedIn: carrier, controllerDeviceCode: "AMI1"),
    ]
}

private func salvageView(
    devices: [Device],
    hubLocation: String? = "AINALRAM-BELT-1",
    starPositions: [String: Position] = ["AINALRAM": Position(x: 0, y: 0, z: 0)],
    meshSystems: Set<String> = ["AINALRAM", "ALPAHARD"],
    salvageUnits: [String: Double] = ["ALPAHARD": 900]
) -> WorldView {
    WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: starPositions,
        meshSystems: meshSystems,
        salvageUnits: salvageUnits,
        eventSystems: [],
        hubLocation: hubLocation,
        now: salvageFixtureNow
    )
}

@Suite("Brain — the salvage readiness verdict")
struct BrainSalvageReadinessTests {
    @Test("a tagged, staged fleet with meshed salvage in reach is ready to launch")
    func readyToLaunch() {
        let view = salvageView(devices: salvageStagedFleet())
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .launch(carrier: "V1", roamCentre: "AINALRAM")
        )
    }

    @Test("an untagged vessel is idle — there is no fallback to any free hull")
    func untaggedVesselIsIdle() {
        let view = salvageView(devices: [salvageDevice("V1", type: Brain.carrierDeviceType, tags: [])])
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "no auto:salvage vessel")
        )
    }

    @Test("a carrier another kind of run already holds is idle, not contended for")
    func aReservedCarrierIsIdle() {
        let view = salvageView(devices: salvageStagedFleet())
        let holder = directiveFixture(id: "R1", kind: .relayRun, deviceCode: "V1")
        #expect(
            Brain.salvageReadiness(view: view, directives: [holder])
                == .idle(reason: "no auto:salvage vessel")
        )
    }

    @Test("a tagged carrier with no mining controller aboard is idle, never a stall")
    func noControllerIsIdle() {
        let view = salvageView(
            devices: [salvageDevice("V1", type: Brain.carrierDeviceType, tags: [Brain.salvageCarrierTag])]
        )
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "V1 has no mining controller aboard")
        )
    }

    @Test("a controller with no adopted drone aboard is idle and names both codes")
    func noDroneIsIdle() {
        let view = salvageView(devices: [
            salvageDevice("V1", type: Brain.carrierDeviceType, tags: [Brain.salvageCarrierTag]),
            salvageDevice(
                "AMI1", type: "ami_mining_controller", stowedIn: "V1", directives: ["gather_salvage"]
            ),
        ])
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "V1's controller AMI1 has adopted no drone aboard")
        )
    }

    @Test("no recognised hub means no roam centre, so idle")
    func noHubIsIdle() {
        let view = salvageView(devices: salvageStagedFleet(), hubLocation: nil)
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "the anchor has no resolvable location")
        )
    }

    @Test("a roam centre the census cannot place is idle and names it")
    func anUnplaceableCentreIsIdle() {
        let view = salvageView(devices: salvageStagedFleet(), starPositions: [:])
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "roam centre AINALRAM is not in the census")
        )
    }

    /// The coupling this design accepts: salvage waits on `tendMesh` rather
    /// than planting its own relay, and the idle must SAY so rather than
    /// presenting the wait as an absence of value.
    @Test("rich salvage in an unmeshed system is idle, named as a mesh wait")
    func unmeshedSalvageIsIdle() {
        let view = salvageView(
            devices: salvageStagedFleet(),
            meshSystems: ["AINALRAM"],
            salvageUnits: ["FARAWAY": 9_000]
        )
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "no meshed salvage system with units left")
        )
    }

    @Test("a meshed system whose salvage is spent is idle")
    func depletedSalvageIsIdle() {
        let view = salvageView(devices: salvageStagedFleet(), salvageUnits: ["ALPAHARD": 0])
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "no meshed salvage system with units left")
        )
    }

    @Test("the lowest-coded tagged vessel wins, so a tick is reproducible")
    func theLowestCodedCarrierWins() {
        var devices = salvageStagedFleet(carrier: "V1")
        devices.append(
            salvageDevice("A0", type: Brain.carrierDeviceType, tags: [Brain.salvageCarrierTag])
        )
        // `A0` sorts first but is unstaged, so the verdict names ITS blocker —
        // proving the carrier is chosen before staging is judged.
        let view = salvageView(devices: devices)
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "A0 has no mining controller aboard")
        )
    }
}

// MARK: - ensureSalvage

private let salvageEnsureNow = Date(timeIntervalSince1970: 9_000)
private let salvageEnsureCarrier = "SALV1"
private let salvageEnsureHubSystem = "SOL"

private func seedSalvageEnsureDevice(
    _ db: Database, code: String, type: String, tags: [String] = [],
    stowedIn: String? = nil, controllerDeviceCode: String? = nil, directives: [String] = []
) throws {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    try Device.insert {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: tags, detail: .object(detail),
            updatedAt: salvageEnsureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

private func seedSalvageEnsureFleet(_ db: Database, carrier: String = salvageEnsureCarrier) throws {
    try seedSalvageEnsureDevice(
        db, code: carrier, type: Brain.carrierDeviceType, tags: [Brain.salvageCarrierTag]
    )
    try seedSalvageEnsureDevice(
        db, code: "AMI1", type: "ami_mining_controller", stowedIn: carrier, directives: ["gather_salvage"]
    )
    try seedSalvageEnsureDevice(
        db, code: "DRONE1", type: "mining_drone", stowedIn: carrier, controllerDeviceCode: "AMI1"
    )
}

/// `seedGrowableWorld`'s meshed hub with no tendMesh carrier and no unmeshed
/// salvage, plus salvage assayed IN the meshed hub system and a staged fleet.
private func seedSalvageEnsureReadyWorld(_ db: Database) throws {
    try seedGrowableWorld(db, carriers: [], salvage: [:])
    try seedSalvageAssay(db, id: "SITE-SOL", system: salvageEnsureHubSystem, totals: ["metal": 900])
    try seedSalvageEnsureFleet(db)
}

private func salvageEnsureDirectives(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in try Directive.all.fetchAll(db) }
}

private func salvageEnsureTick(_ database: any DatabaseWriter) async {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(salvageEnsureNow)
        $0.uuid = .incrementing
    } operation: {
        _ = await Brain(now: salvageEnsureNow).evaluateOnce()
    }
}

@Suite("Brain — ensureSalvage")
struct BrainEnsureSalvageTests {
    @Test func readyFleetWithNoLiveSalvageInsertsExactlyOneRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSalvageEnsureReadyWorld(db) }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        let salvage = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(salvage.kind == .salvageRun)
        #expect(salvage.deviceCode == salvageEnsureCarrier)
        #expect(salvage.fleetTag == SalvageRun.defaultFleetTag)
        #expect(salvage.roamCentre == salvageEnsureHubSystem)
        #expect(salvage.step == SalvageRun().firstStep)
        #expect(salvage.status == .running)
        // Claimed at preflight, never eager-written — an eager one goes stale.
        #expect(salvage.controllerCode == nil)
        #expect(salvage.returnToOrigin == false)
    }

    @Test func aSecondTickWithTheLaunchedRowStillLiveInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSalvageEnsureReadyWorld(db) }
        await salvageEnsureTick(database)
        let afterFirst = try await salvageEnsureDirectives(database)
        #expect(afterFirst.count == 1)

        await salvageEnsureTick(database)

        let afterSecond = try await salvageEnsureDirectives(database)
        #expect(afterSecond == afterFirst, "the row the first tick launched already owns the fleet")
    }

    /// A run the OPERATOR launched satisfies the goal exactly as one the brain
    /// launched does — membership is by kind, never provenance.
    @Test func anOperatorLaunchedRunIsAdoptedNotDuplicated() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "OPERATOR", kind: .salvageRun, status: .running,
                deviceCode: "OTHERVESSEL", fleetTag: SalvageRun.defaultFleetTag
            )
        }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        #expect(directives.count == 1)
        #expect(directives.first?.id == "OPERATOR")
    }

    @Test(arguments: [DirectiveStatus.running, .needsAttention, .paused])
    func aLiveSalvageInAnyOwningStatusBlocksRelaunch(_ status: DirectiveStatus) async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "HELD", kind: .salvageRun, status: status,
                deviceCode: salvageEnsureCarrier, fleetTag: SalvageRun.defaultFleetTag
            )
        }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        #expect(directives.count == 1)
        #expect(directives.first?.id == "HELD")
    }

    @Test(arguments: [DirectiveStatus.completed, .cancelled])
    func aFinishedSalvageDoesNotBlockAFreshRun(_ status: DirectiveStatus) async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "DONE", kind: .salvageRun, status: status,
                deviceCode: salvageEnsureCarrier, fleetTag: SalvageRun.defaultFleetTag
            )
        }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        #expect(directives.count == 2)
        #expect(directives.contains { $0.id != "DONE" && $0.kind == .salvageRun })
    }

    @Test func anIdleVerdictInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        // The ready world minus the fleet: no tagged vessel, so no launch.
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSalvageAssay(db, id: "SITE-SOL", system: salvageEnsureHubSystem, totals: ["metal": 900])
        }

        await salvageEnsureTick(database)

        #expect(try await salvageEnsureDirectives(database).isEmpty)
    }
}
