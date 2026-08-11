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
        availableCommands: [], features: fixtureFeatures(for: type), tags: tags,
        detail: .object(detail),
        updatedAt: salvageFixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A fully staged salvage vessel: tagged, a mining controller stowed aboard
/// offering `gather_salvage`, and one drone that controller has adopted.
private func salvageStagedFleet(carrier: String = "V1") -> [Device] {
    [
        salvageDevice(carrier, type: "heaven_vessel", tags: [Brain.salvageCarrierTag]),
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

    /// The carrier gate is capability, not type: a staged `racing_vessel`
    /// wearing the fleet tag must be exactly as flyable as a HEAVEN vessel.
    @Test("a tagged, staged racing vessel is a salvage carrier")
    func racingVesselIsASalvageCarrier() {
        let view = salvageView(devices: [
            salvageDevice("V1", type: "racing_vessel", tags: [Brain.salvageCarrierTag]),
            salvageDevice(
                "AMI1", type: "ami_mining_controller", stowedIn: "V1", directives: ["gather_salvage"]
            ),
            salvageDevice("DRONE1", type: "mining_drone", stowedIn: "V1", controllerDeviceCode: "AMI1"),
        ])
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .launch(carrier: "V1", roamCentre: "AINALRAM")
        )
    }

    /// A tag on a hull that cannot carry the fleet is a misapplied opt-in —
    /// the idle reason names the device so the remedy reads as "move the tag".
    @Test("a tagged non-carrier is named in the idle reason")
    func taggedNonCarrierIsNamedInTheIdleReason() {
        let view = salvageView(devices: [
            salvageDevice("F1", type: "cargo_freighter", tags: [Brain.salvageCarrierTag])
        ])
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "no \(Brain.salvageCarrierTag) vessel — F1 is tagged \(Brain.salvageCarrierTag) but is not a carrier hull")
        )
    }

    @Test("an untagged vessel is idle — there is no fallback to any free hull")
    func untaggedVesselIsIdle() {
        let view = salvageView(devices: [salvageDevice("V1", type: "heaven_vessel", tags: [])])
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
            devices: [salvageDevice("V1", type: "heaven_vessel", tags: [Brain.salvageCarrierTag])]
        )
        #expect(
            Brain.salvageReadiness(view: view, directives: [])
                == .idle(reason: "V1 has no mining controller aboard")
        )
    }

    @Test("a controller with no adopted drone aboard is idle and names both codes")
    func noDroneIsIdle() {
        let view = salvageView(devices: [
            salvageDevice("V1", type: "heaven_vessel", tags: [Brain.salvageCarrierTag]),
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
            salvageDevice("A0", type: "heaven_vessel", tags: [Brain.salvageCarrierTag])
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
            availableCommands: [], features: fixtureFeatures(for: type), tags: tags,
            detail: .object(detail),
            updatedAt: salvageEnsureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

private func seedSalvageEnsureFleet(_ db: Database, carrier: String = salvageEnsureCarrier) throws {
    try seedSalvageEnsureDevice(
        db, code: carrier, type: "heaven_vessel", tags: [Brain.salvageCarrierTag]
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

    /// The snapshot-level check cannot see a row written after the tick's own
    /// world read, so the guard INSIDE the write transaction is the only thing
    /// standing between two ticks and two rows. Driving `ensureOne` directly
    /// with a deliberately stale snapshot is the one way to reach it.
    @Test func theInTransactionRecheckIsWhatStopsTheSecondInsert() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSalvageEnsureReadyWorld(db) }

        let stale = Brain.Snapshot(
            view: try await database.read { db in
                try WorldView.read(from: db, now: salvageEnsureNow)
            },
            directives: [],          // read BEFORE either insert, and never refreshed
            log: [:], hubFootprint: nil
        )
        let theatre = try #require(stale.view.theatres.first { $0.isOperational })
        // Each call names a DIFFERENT vessel. With one vessel the reservation
        // guard would refuse the second call and the liveness check would never
        // be reached — the two guards overlap, and only this separates them.
        let brain = Brain(now: salvageEnsureNow)
        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            for vessel in ["SALV1", "SALV2"] {
                await brain.ensureOne(.salvageRun, theatre: theatre, snapshot: stale, database: database) {
                    directiveFixture(
                        id: "ROW-\(vessel)", kind: .salvageRun,
                        deviceCode: vessel, fleetTag: nil, theatreDepot: theatre.depot
                    )
                }
            }
        }

        let rows = try await database.read { db in
            try Directive.where { $0.kind.eq(DirectiveKind.salvageRun) }.fetchAll(db)
        }
        #expect(rows.count == 1, "the second call must be refused inside the transaction")
        #expect(rows.first?.id == "ROW-SALV1")
    }

    /// Reaches the LIVENESS path rather than the reservation gate: the live row
    /// sits on another vessel and carries no fleet tag, so it reserves nothing
    /// the candidate carrier needs and `salvageReadiness` still says launch.
    @Test func aLiveUntaggedRunOnAnotherVesselStillBlocksBbyKind() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "ELSEWHERE", kind: .salvageRun, status: .running,
                deviceCode: "UNRELATED", fleetTag: nil
            )
        }

        await salvageEnsureTick(database)

        let rows = try await salvageEnsureDirectives(database).filter { $0.kind == .salvageRun }
        #expect(rows.count == 1)
        #expect(rows.first?.id == "ELSEWHERE")
    }

    /// A vessel wearing two automation tags must not be committed twice in one
    /// tick. The survey launch lands first and the salvage launch must decline,
    /// even though the snapshot both read predates either row.
    @Test func aDoubleTaggedVesselIsCommittedOnlyOnce() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSalvageAssay(db, id: "SITE-SOL", system: salvageEnsureHubSystem, totals: ["metal": 900])
            // One hull, both opt-in tags, staged for both automations.
            try seedSalvageEnsureDevice(
                db, code: "BOTH", type: "heaven_vessel",
                tags: [Brain.salvageCarrierTag, Brain.surveyCarrierTag]
            )
            try seedSalvageEnsureDevice(
                db, code: "AMI1", type: "ami_mining_controller", stowedIn: "BOTH",
                directives: ["gather_salvage"]
            )
            try seedSalvageEnsureDevice(
                db, code: "DRONE1", type: "mining_drone", stowedIn: "BOTH", controllerDeviceCode: "AMI1"
            )
            try seedSalvageEnsureDevice(
                db, code: "SAMI", type: "ami_survey_controller", stowedIn: "BOTH",
                directives: ["survey_system"]
            )
            try seedSalvageEnsureDevice(
                db, code: "SDRONE", type: "survey_drone", stowedIn: "BOTH", controllerDeviceCode: "SAMI"
            )
        }

        await salvageEnsureTick(database)

        let owners = try await salvageEnsureDirectives(database).filter { $0.deviceCode == "BOTH" }
        #expect(owners.count == 1, "two directives owning one hull is a double commit")
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

// MARK: - Reservation disjointness

/// One fleet: a tagged carrier with a controller and a drone stowed aboard.
private func taggedFleet(carrier: String, controller: String, drone: String, tag: String) -> [Device] {
    [
        salvageDevice(carrier, type: "heaven_vessel", tags: [tag]),
        salvageDevice(controller, type: "ami_mining_controller", tags: [tag], stowedIn: carrier),
        salvageDevice(drone, type: "mining_drone", tags: [tag], stowedIn: carrier, controllerDeviceCode: controller),
    ]
}

/// The three live automations each own a carrier. `reservedDevices` closes over
/// stow in BOTH directions and over adoption, so a cross-link would pull a
/// second carrier into a directive's set — and `salvageReadiness` would then
/// report "no auto:salvage vessel" while the vessel sat idle in front of it.
/// That failure reads exactly like the honest idle, so it is pinned here.
@Suite("Brain — the three carriers reserve disjointly")
struct BrainReservationDisjointnessTests {
    @Test func eachDirectiveReservesOnlyItsOwnCarrier() {
        let devices = (
            taggedFleet(carrier: "MESH1", controller: "MC", drone: "MD", tag: Brain.carrierTag)
                + taggedFleet(carrier: "SALV1", controller: "SC", drone: "SD", tag: Brain.salvageCarrierTag)
                + taggedFleet(carrier: "SURV1", controller: "QC", drone: "QD", tag: Brain.surveyCarrierTag)
        ).reduce(into: [String: Device]()) { $0[$1.deviceCode] = $1 }

        let carriers = ["MESH1", "SALV1", "SURV1"]
        let directives = [
            directiveFixture(id: "R", kind: .relayRun, deviceCode: "MESH1"),
            directiveFixture(
                id: "S", kind: .salvageRun, deviceCode: "SALV1", fleetTag: Brain.salvageCarrierTag
            ),
            directiveFixture(id: "Q", kind: .surveyRun, deviceCode: "SURV1"),
        ]

        for directive in directives {
            let reserved = Brain.reservedDevices(directives: [directive], devices: devices)
            #expect(
                carriers.filter { reserved.contains($0) } == [directive.deviceCode],
                "\(directive.id) reserved carriers beyond its own"
            )
        }
    }
}

// MARK: - The widened brain-managed stall set

/// A halted row of `kind` carrying `reason`, as `DirectiveExecutor.stall` leaves one.
private func stalledRow(
    id: String, kind: DirectiveKind, reason: DirectiveAttentionReason, step: String
) -> Directive {
    var directive = directiveFixture(id: id, kind: kind, status: .needsAttention, deviceCode: "V1")
    directive.attentionReason = reason
    directive.step = step
    return directive
}

@Suite("Brain — the stall set widens by kind")
struct BrainWidenedStallTests {
    @Test("a retryable salvage stall is retried on the first look")
    func aRetryableSalvageStallIsRetried() {
        let row = stalledRow(
            id: "S1", kind: .salvageRun, reason: .salvageBodyNotDepleted, step: "awaiting"
        )
        #expect(
            Brain.stallResponse(for: row, log: [], now: Date(timeIntervalSince1970: 10_000))
                == .retry(
                    directiveID: "S1", reason: .salvageBodyNotDepleted,
                    attempt: 1, lastAttemptAt: nil
                )
        )
    }

    @Test("a salvage stall that has spent its budget escalates")
    func anExhaustedSalvageBudgetEscalates() {
        let now = Date(timeIntervalSince1970: 100_000)
        let row = stalledRow(
            id: "S1", kind: .salvageRun, reason: .salvageBodyNotDepleted, step: "awaiting"
        )
        let spent = (0..<Brain.retryBudget).map { index in
            DirectiveLogEntry(
                id: "E\(index)", directiveID: "S1", deviceCode: nil, kind: .resolved,
                summary: "retry", step: "awaiting", operationID: nil, eventID: nil,
                occurredAt: now.addingTimeInterval(Double(-3_600 * (Brain.retryBudget - index)))
            )
        }
        #expect(
            Brain.stallResponse(for: row, log: spent, now: now)
                == .escalated(directiveID: "S1", reason: .salvageBodyNotDepleted)
        )
    }

    @Test("an escalate-classified salvage stall escalates on sight")
    func dronesNotRecoveredEscalatesImmediately() {
        let row = stalledRow(
            id: "S2", kind: .salvageRun, reason: .dronesNotRecovered, step: "verifying"
        )
        #expect(
            Brain.stallResponse(for: row, log: [], now: Date(timeIntervalSince1970: 0))
                == .escalated(directiveID: "S2", reason: .dronesNotRecovered)
        )
    }

    @Test("a haul stall is managed too")
    func haulStallsAreManaged() {
        let row = stalledRow(id: "H1", kind: .haulRun, reason: .commandRejected, step: "confirming")
        #expect(Brain.brainManagedStall(row) == .commandRejected)
    }

    /// Deliberately outside the set: a Survey Run's stalls stay the operator's,
    /// and a restock run's too.
    @Test(arguments: [DirectiveKind.surveyRun, .restockRun])
    func otherKindsStayTheOperators(_ kind: DirectiveKind) {
        let row = stalledRow(id: "Q1", kind: kind, reason: .commandRejected, step: "travelling")
        #expect(Brain.brainManagedStall(row) == nil)
        #expect(Brain.stallResponse(for: row, log: [], now: Date(timeIntervalSince1970: 0)) == nil)
    }

    @Test("a salvage row that is not halted is not a managed stall")
    func aRunningSalvageRowIsNotAStall() {
        let row = directiveFixture(id: "S3", kind: .salvageRun, status: .running, deviceCode: "V1")
        #expect(Brain.brainManagedStall(row) == nil)
    }
}

// MARK: - haulReadiness / ensureHaul

private func haulController(_ code: String, tags: [String], directives: [String] = ["ferry"]) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: "ami_transport_controller", replicantCode: "R1",
        status: "idle", location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [],
        tags: tags, detail: .object(detail),
        updatedAt: salvageEnsureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func haulView(devices: [Device], hubLocation: String? = "SOL-3") -> WorldView {
    WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: ["SOL": Position(x: 0, y: 0, z: 0)],
        meshSystems: ["SOL"], salvageUnits: [:], eventSystems: [],
        hubLocation: hubLocation, now: salvageEnsureNow
    )
}

@Suite("Brain — the haul readiness verdict")
struct BrainHaulReadinessTests {
    @Test("a tagged ferry controller with a hub launches on the lowest code")
    func theLowestCodedControllerLaunches() {
        let view = haulView(devices: [
            haulController("T2", tags: [HaulRun.defaultFleetTag]),
            haulController("T1", tags: [HaulRun.defaultFleetTag]),
        ])
        #expect(Brain.haulReadiness(view: view, directives: []) == .launch(controller: "T1"))
    }

    @Test("an untagged controller is idle — untagging is the operator's off-switch")
    func anUntaggedControllerIsIdle() {
        let view = haulView(devices: [haulController("T1", tags: [])])
        #expect(Brain.haulReadiness(view: view, directives: []) == .idle(reason: "no free auto:haul controller offering ferry"))
    }

    @Test("a tagged device that does not offer ferry is not a haul controller")
    func aNonFerryDeviceIsIdle() {
        let view = haulView(devices: [haulController("T1", tags: [HaulRun.defaultFleetTag], directives: [])])
        #expect(Brain.haulReadiness(view: view, directives: []) == .idle(reason: "no free auto:haul controller offering ferry"))
    }

    @Test("no hub on the mesh is idle rather than hauling to a stale constant")
    func noHubIsIdle() {
        let view = haulView(devices: [haulController("T1", tags: [HaulRun.defaultFleetTag])], hubLocation: nil)
        #expect(Brain.haulReadiness(view: view, directives: []) == .idle(reason: "no print hub on the mesh"))
    }

    /// The forward-shaping rule `mine` will rely on. A liveness rule written
    /// over kind alone would make both of these read the same.
    @Test("a per-site row is not the general drainer, and the default-tagged one is")
    func perSiteRowsAreNotTheGeneralDrainer() {
        let perSite = directiveFixture(
            id: "PS", kind: .haulRun, deviceCode: "T9", fleetTag: "auto:haul:ALPAHARD"
        )
        let general = directiveFixture(
            id: "G", kind: .haulRun, deviceCode: "T1", fleetTag: HaulRun.defaultFleetTag
        )
        let untagged = directiveFixture(id: "U", kind: .haulRun, deviceCode: "T1", fleetTag: nil)
        #expect(Brain.isGeneralHaul(perSite) == false)
        #expect(Brain.isGeneralHaul(general) == true)
        #expect(Brain.isGeneralHaul(untagged) == true, "a nil tag falls back to the default")
    }
}

@Suite("Brain — ensureHaul")
struct BrainEnsureHaulTests {
    private func seedHaulReadyWorld(_ db: Database) throws {
        try seedGrowableWorld(db, carriers: [], salvage: [:])
        try Device.insert { haulController("T1", tags: [HaulRun.defaultFleetTag]) }.execute(db)
    }

    @Test func aTaggedControllerAndAHubLaunchOneGeneralDrainer() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try self.seedHaulReadyWorld(db) }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        let haul = try #require(directives.first { $0.kind == .haulRun })
        #expect(directives.count == 1)
        #expect(haul.deviceCode == "T1")
        #expect(haul.fleetTag == HaulRun.defaultFleetTag)
        #expect(haul.step == HaulRun().firstStep)
        #expect(haul.originDesignation == "SOL")
    }

    @Test func aSecondTickInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try self.seedHaulReadyWorld(db) }
        await salvageEnsureTick(database)
        let afterFirst = try await salvageEnsureDirectives(database)

        await salvageEnsureTick(database)

        #expect(try await salvageEnsureDirectives(database) == afterFirst)
    }

    /// The forward-shaping assertion, driven through the real tick: a live
    /// per-site row must NOT be mistaken for the general drainer.
    @Test func aPerSiteRowDoesNotSatisfyTheGeneralDrainersLiveness() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try self.seedHaulReadyWorld(db)
            try seedDirective(
                db, id: "PERSITE", kind: .haulRun, status: .running,
                deviceCode: "T9", fleetTag: "auto:haul:ALPAHARD"
            )
        }

        await salvageEnsureTick(database)

        let hauls = try await salvageEnsureDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 2)
        #expect(hauls.filter { $0.fleetTag == HaulRun.defaultFleetTag }.count == 1)
        #expect(hauls.contains { $0.id == "PERSITE" })
    }
}
