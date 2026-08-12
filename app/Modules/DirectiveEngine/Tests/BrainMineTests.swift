//
//  BrainMineTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.mineReadiness` as a pure verdict table, and the DB-backed liveness of
//  `ensureMine` and the per-mine ferry rows that stand beside the general
//  drainer without being mistaken for it.
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

private let mineNow = Date(timeIntervalSince1970: 7_000)
private let mineHub = "SOL-3"
private let mineHubSystem = "SOL"
private let mineCarrier = "CARRIER1"
private let mineBelt = "SOL-BELT-1"
private let mineTransportType = "ami_transport_controller"

/// A mine-fleet device. `collect` writes the `ferry` config a transport
/// controller carries once armed, which is what the ferry preference reads.
private func mineDevice(
    _ code: String,
    type: String,
    tags: [String] = [MineRecipe.fleetTag],
    location: String? = mineHub,
    status: String = "idle",
    directives: [String] = [],
    directive: String? = nil,
    directiveStatus: String? = nil,
    collect: String? = nil
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    if let directive {
        var block: [String: JSONValue] = ["name": .string(directive)]
        if let collect { block["config"] = .object(["collect": .string(collect)]) }
        detail["ami_directive"] = .object(block)
    }
    if let directiveStatus {
        detail["ami_directive_status"] = .string(directiveStatus)
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [],
        tags: tags, detail: .object(detail),
        updatedAt: mineNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// One free device per recipe slot, standing at `hub` — a fully printed fleet.
private func minePrintedFleet(at hub: String = mineHub, suffix: String = "") -> [Device] {
    MineRecipe.all.flatMap { type, quantity in
        (0..<quantity).map { index in
            mineDevice("\(type)\(suffix)\(index)", type: type, location: hub)
        }
    }
}

private func mineCarrierDevice(
    _ code: String = mineCarrier, status: String = "idle", tags: [String] = [MineRecipe.carrierTag],
    location: String = mineHub
) -> Device {
    mineDevice(code, type: MineRecipe.carrierDeviceType, tags: tags, location: location, status: status)
}

private let mineRichBelt = ["SOL": [BeltInfo(designation: mineBelt, beltClass: .rich)]]

private func mineWorldView(
    devices: [Device],
    depot: String? = mineHub,
    belts: [String: [BeltInfo]] = mineRichBelt,
    meshSystems: Set<String> = ["SOL"],
    starPositions: [String: Position] = ["SOL": Position(x: 0, y: 0, z: 0)]
) -> WorldView {
    let theatre = singleOperationalTheatre(depot: depot)
    return WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: starPositions,
        meshSystems: meshSystems,
        salvageUnits: [:],
        eventSystems: [],
        theatres: theatre.theatres,
        components: theatre.components,
        beltsBySystem: belts,
        now: mineNow
    )
}

@Suite("Brain — the mine readiness verdict")
struct BrainMineReadinessTests {
    @Test("a printed fleet, an idle carrier and a meshed belt launch an install")
    func aFullBoardLaunches() {
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice()])
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .launch(carrier: mineCarrier, belt: mineBelt)
        )
    }

    @Test("no operational theatre is idle before anything else is asked")
    func noHubIsIdle() {
        let view = mineWorldView(
            devices: minePrintedFleet() + [mineCarrierDevice()], depot: nil
        )
        #expect(Brain.mineReadiness(view: view, directives: []) == .idle(reason: "no operational theatre"))
    }

    @Test("nothing printed reads differently from a fleet part-way printed")
    func nothingPrintedIsIdle() {
        let view = mineWorldView(devices: [mineCarrierDevice()])
        #expect(
            Brain.mineReadiness(view: view, directives: []) == .idle(reason: "no printed mine fleet")
        )
    }

    @Test("a part-printed fleet names the missing type and count")
    func aPartPrintedFleetNamesWhatIsMissing() {
        let fleet = minePrintedFleet().filter { $0.deviceType != "mining_drone" }
        let view = mineWorldView(devices: fleet + [mineCarrierDevice()])
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .idle(reason: "mine fleet incomplete — missing mining_drone×3")
        )
    }

    @Test("a fleet with no carrier to deliver it is idle")
    func noCarrierIsIdle() {
        let view = mineWorldView(devices: minePrintedFleet())
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .idle(reason: "no idle auto:carrier surge carrier")
        )
    }

    @Test("a carrier that is not at rest is idle")
    func aBusyCarrierIsIdle() {
        let view = mineWorldView(
            devices: minePrintedFleet() + [mineCarrierDevice(status: "travelling")]
        )
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .idle(reason: "no idle auto:carrier surge carrier")
        )
    }

    /// The verdict must not report a launch `ensureOne` will decline inside its
    /// own transaction — the lesson `haulReadiness` already carries.
    @Test("a carrier another directive holds is idle, not launched at")
    func aReservedCarrierIsIdle() {
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice()])
        let holder = directiveFixture(id: "R1", kind: .relayRun, deviceCode: mineCarrier)
        #expect(
            Brain.mineReadiness(view: view, directives: [holder])
                == .idle(reason: "no idle auto:carrier surge carrier")
        )
    }

    @Test("no meshed belt left to site is idle")
    func noCandidateBeltIsIdle() {
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice()], belts: [:])
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .idle(reason: "no meshed candidate belt")
        )
    }

    /// A belt excluded by occupancy reads differently from a board that never
    /// had a candidate: one is a full estate, the other a mesh that reaches none.
    @Test("a belt already holding an installed mine is not sited a second time")
    func anInstalledBeltIsOccupied() {
        let installed = mineDevice("MC-INSTALLED", type: "ami_mining_controller", location: mineBelt)
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice(), installed])
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .idle(reason: "every candidate belt taken")
        )
    }

    /// `MineRecipe.installedBelts` filters `location != hub`, so a mine standing
    /// on the hub's own belt is invisible to every installed query — the siting
    /// must never offer it in the first place.
    @Test("the hub's own belt is never sited, even as the only candidate")
    func theHubsOwnBeltIsNeverSited() {
        let view = mineWorldView(
            devices: minePrintedFleet(at: mineBelt) + [mineCarrierDevice(location: mineBelt)],
            depot: mineBelt
        )
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .idle(reason: "no meshed candidate belt")
        )
    }

    /// Two candidates, the better one already being installed at: the verdict
    /// takes the second rather than sending a second fleet to the same belt.
    @Test("the belt a live mine run targets is excluded from siting")
    func aLiveMineRunsBeltIsOccupied() {
        let view = mineWorldView(
            devices: minePrintedFleet() + [mineCarrierDevice()],
            belts: [
                "SOL": [BeltInfo(designation: mineBelt, beltClass: .rich)],
                "VEGA": [BeltInfo(designation: "VEGA-BELT-1", beltClass: .moderate)],
            ],
            meshSystems: ["SOL", "VEGA"],
            starPositions: ["SOL": Position(x: 0, y: 0, z: 0), "VEGA": Position(x: 1, y: 0, z: 0)]
        )
        let live = directiveFixture(
            id: "M1", kind: .mineRun, deviceCode: "OTHERCARRIER",
            fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
        )
        #expect(
            Brain.mineReadiness(view: view, directives: []) == .launch(carrier: mineCarrier, belt: mineBelt)
        )
        #expect(
            Brain.mineReadiness(view: view, directives: [live])
                == .launch(carrier: mineCarrier, belt: "VEGA-BELT-1")
        )
    }

    /// A second operational theatre's own depot can be belt-shaped
    /// (`Theatre.swift`'s own `AINALRAM-BELT-1` example): a fleet staged
    /// there must not read as an installed, occupying mine.
    @Test("a staged fleet at a second theatre's own depot is not occupied")
    func aSecondTheatresStagedFleetIsNotOccupied() {
        let hubA = "HUB-A-DEPOT"
        let hubB = "HUB-B-BELT-1"
        let devices = minePrintedFleet(at: hubA) + [mineCarrierDevice(location: hubA)]
            + [mineDevice("MC-STAGED-B", type: "ami_mining_controller", location: hubB)]
        let view = WorldView(
            devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
            starPositions: ["HUB-A": Position(x: 0, y: 0, z: 0), "HUB-B": Position(x: 1, y: 0, z: 0)],
            meshSystems: ["HUB-A", "HUB-B"],
            salvageUnits: [:], eventSystems: [],
            theatres: [
                Theatre(depot: hubA, system: "HUB-A", origin: .derived, readiness: .operational, stock: 0),
                Theatre(depot: hubB, system: "HUB-B", origin: .derived, readiness: .operational, stock: 0),
            ],
            beltsBySystem: ["HUB-B": [BeltInfo(designation: hubB, beltClass: .rich)]],
            now: mineNow
        )
        #expect(
            Brain.mineReadiness(view: view, directives: [])
                == .launch(carrier: mineCarrier, belt: hubB)
        )
    }
}

@Suite("Brain — the mine ferry controller")
struct BrainMineFerryControllerTests {
    @Test("the controller already ferrying the belt is preferred over a lower code")
    func theArmedControllerWins() {
        let view = mineWorldView(devices: [
            mineDevice("TC-A", type: mineTransportType),
            mineDevice("TC-B", type: mineTransportType, directive: "ferry", collect: mineBelt),
        ])
        #expect(
            Brain.mineFerryController(for: mineBelt, at: mineHub, view: view, directives: []) == "TC-B"
        )
    }

    @Test("a controller ferrying another belt is left alone")
    func aControllerOnAnotherBeltIsNotStolen() {
        let view = mineWorldView(devices: [
            mineDevice("TC-A", type: mineTransportType, directive: "ferry", collect: "VEGA-BELT-1"),
            mineDevice("TC-B", type: mineTransportType),
        ])
        #expect(Brain.mineFerryController(for: mineBelt, at: mineHub, view: view, directives: []) == "TC-B")
    }

    @Test("a controller another directive holds is not offered")
    func aReservedControllerIsNotOffered() {
        let view = mineWorldView(devices: [mineDevice("TC-A", type: mineTransportType)])
        let holder = directiveFixture(
            id: "H", kind: .haulRun, deviceCode: "TC-A", targets: ["VEGA-BELT-1"]
        )
        #expect(Brain.mineFerryController(for: mineBelt, at: mineHub, view: view, directives: [holder]) == nil)
    }

    /// `collect` is a `ferry` key. Read off any other directive it names a
    /// coincidence, not a haul this belt is already getting.
    @Test("a controller running a non-ferry directive is not the belt's ferry")
    func aNonFerryDirectiveIsNotAFerry() {
        let view = mineWorldView(devices: [
            mineDevice("TC-A", type: mineTransportType, directive: "gather_evenly", collect: mineBelt),
            mineDevice("TC-B", type: mineTransportType, directive: "ferry", collect: mineBelt),
        ])
        #expect(Brain.mineFerryController(for: mineBelt, at: mineHub, view: view, directives: []) == "TC-B")
    }

    @Test("an untagged transport controller belongs to no mine")
    func anUntaggedControllerIsNotOffered() {
        let view = mineWorldView(devices: [mineDevice("TC-A", type: mineTransportType, tags: [])])
        #expect(Brain.mineFerryController(for: mineBelt, at: mineHub, view: view, directives: []) == nil)
    }
}

@Suite("Brain — the mine goal status")
struct BrainMineStatusTests {
    @Test("a live running mine run reports launched with its belt as focus")
    func aLiveRunReportsLaunched() {
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice()])
        let live = directiveFixture(
            id: "M1", kind: .mineRun, status: .running, deviceCode: mineCarrier,
            fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
        )
        #expect(
            Brain.mineStatus(directives: [live], view: view)
                == .launched(vessel: mineCarrier, focus: mineBelt, status: .running)
        )
    }

    @Test("a needsAttention live run carries that status through, not running")
    func aNeedsAttentionRunReportsHalted() {
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice()])
        let live = directiveFixture(
            id: "M1", kind: .mineRun, status: .needsAttention, deviceCode: mineCarrier,
            fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
        )
        #expect(
            Brain.mineStatus(directives: [live], view: view)
                == .launched(vessel: mineCarrier, focus: mineBelt, status: .needsAttention)
        )
    }

    @Test("a full board with no live run reports ready, not launched")
    func readyWhenNoLiveRun() {
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice()])
        #expect(Brain.mineStatus(directives: [], view: view) == .ready(vessel: mineCarrier))
    }

    @Test("nothing printed reports idle with mineReadiness's own reason")
    func idleWhenNothingPrinted() {
        let view = mineWorldView(devices: [mineCarrierDevice()])
        #expect(
            Brain.mineStatus(directives: [], view: view) == .idle(reason: "no printed mine fleet")
        )
    }

    @Test("a completed run does not count as live, falling through to readiness")
    func aCompletedRunFallsThroughToReadiness() {
        let view = mineWorldView(devices: minePrintedFleet() + [mineCarrierDevice()])
        let completed = directiveFixture(
            id: "M1", kind: .mineRun, status: .completed, deviceCode: "OTHERCARRIER",
            fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
        )
        #expect(Brain.mineStatus(directives: [completed], view: view) == .ready(vessel: mineCarrier))
    }
}

@Suite("Brain — per-mine health")
struct BrainMineHealthTests {
    private func healthWorld(
        miningStatus: String? = "active",
        surveyStatus: String? = "active",
        ferryCollect: String? = mineBelt
    ) -> WorldView {
        mineWorldView(devices: [
            mineDevice(
                "MC1", type: "ami_mining_controller", location: mineBelt,
                directive: MineRun.miningDirective, directiveStatus: miningStatus
            ),
            mineDevice(
                "SC1", type: "ami_survey_controller", location: mineBelt,
                directive: MineRun.surveyDirective, directiveStatus: surveyStatus
            ),
            mineDevice(
                "TC1", type: mineTransportType,
                directive: ferryCollect.map { _ in "ferry" }, directiveStatus: "active",
                collect: ferryCollect
            ),
        ])
    }

    @Test("all three active reads fully healthy")
    func allActive() {
        #expect(
            Brain.mineHealth(view: healthWorld(), directives: [])
                == [BrainMineHealth(belt: mineBelt, miningActive: true, surveyActive: true, ferryInForce: true)]
        )
    }

    @Test("a paused mining directive reads mining inactive, the rest unaffected")
    func lapsedMining() {
        #expect(
            Brain.mineHealth(view: healthWorld(miningStatus: "paused"), directives: [])
                == [BrainMineHealth(belt: mineBelt, miningActive: false, surveyActive: true, ferryInForce: true)]
        )
    }

    @Test("no transport controller collecting the belt reads ferry not in force")
    func lapsedFerry() {
        #expect(
            Brain.mineHealth(view: healthWorld(ferryCollect: nil), directives: [])
                == [BrainMineHealth(belt: mineBelt, miningActive: true, surveyActive: true, ferryInForce: false)]
        )
    }

    @Test("an uninstalled belt reports no health row at all")
    func noInstalledBeltIsEmpty() {
        #expect(Brain.mineHealth(view: mineWorldView(devices: [mineCarrierDevice()]), directives: []).isEmpty)
    }

    /// `MineRun` drops the fleet at the belt (making `installedBelts` true)
    /// BEFORE arming any directive — a real multi-tick window. A live run
    /// still targeting the belt must read as mid-install, never as a fault.
    @Test("a belt a live mine run still targets reports no health row at all")
    func aBeltALiveMineRunTargetsIsExcluded() {
        let live = directiveFixture(
            id: "M1", kind: .mineRun, status: .running, deviceCode: mineCarrier,
            fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
        )
        #expect(
            Brain.mineHealth(view: healthWorld(miningStatus: nil, surveyStatus: nil, ferryCollect: nil), directives: [live])
                .isEmpty
        )
    }

    @Test("the same belt, its mine run completed, reports its real flags")
    func theSameBeltOnceTheMineRunCompletesReportsRealFlags() {
        let completed = directiveFixture(
            id: "M1", kind: .mineRun, status: .completed, deviceCode: mineCarrier,
            fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
        )
        #expect(
            Brain.mineHealth(view: healthWorld(miningStatus: nil, surveyStatus: nil, ferryCollect: nil), directives: [completed])
                == [BrainMineHealth(belt: mineBelt, miningActive: false, surveyActive: false, ferryInForce: false)]
        )
    }
}

@Suite("Brain — installed mine belts across theatres")
struct BrainInstalledMineBeltsAcrossTheatresTests {
    /// A printed, undispatched fleet is tagged `auto:mine` and standing at ITS
    /// OWN depot by construction — a second operational theatre must not make
    /// that depot read as an installed belt.
    @Test("a fleet staged at one theatre's depot is never a belt because a second theatre exists")
    func stagedFleetAtOneDepotIsNeverABeltElsewhere() {
        let hubA = "HUB-A-BELT-1"
        let hubB = "HUB-B-BELT-1"
        let realBelt = "HUB-A-ORE-BELT-1"
        let devices = [
            mineDevice("MC-STAGED", type: "ami_mining_controller", location: hubA),
            mineDevice("MC-INSTALLED", type: "ami_mining_controller", location: realBelt),
        ]
        let view = WorldView(
            devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
            starPositions: [:], meshSystems: [], salvageUnits: [:], eventSystems: [],
            theatres: [
                Theatre(depot: hubA, system: "HUB-A", origin: .derived, readiness: .operational, stock: 0),
                Theatre(depot: hubB, system: "HUB-B", origin: .derived, readiness: .operational, stock: 0),
            ],
            now: mineNow
        )

        #expect(Brain.installedMineBelts(view: view) == [realBelt])
    }
}

@Suite("BrainReport — mine defaults")
struct BrainReportMineDefaultsTests {
    @Test("mine defaults to idle not evaluated, mines defaults to empty")
    func defaults() {
        let report = BrainReport(
            decision: .idle(reason: "nothing"),
            ranked: [], theatres: [],
            limits: BrainLimits(
                actionsRemaining: 0, actionsLimit: 0, actionsFloor: 0,
                hubStock: nil, hubStockFetchedAt: nil, spendFloor: 0, rateLimitedAt: nil
            ),
            survey: .idle(reason: "none"),
            observedAt: mineNow
        )
        #expect(report.mine == .idle(reason: "not evaluated"))
        #expect(report.mines == [])
    }
}

// MARK: - The managed stall set

@Suite("Brain — the mine run joins the managed kinds")
struct BrainMineManagedKindTests {
    @Test("a mine run stall is the brain's to retry, a fleet print is the operator's")
    func mineRunIsManagedAndFleetPrintIsNot() {
        #expect(Brain.brainManagedKinds.contains(.mineRun))
        #expect(Brain.brainManagedKinds.contains(.mineFleetPrint) == false)
    }
}

// MARK: - ensureMine / ensureMineFerries

private func seedMineDevice(_ db: Database, _ device: Device) throws {
    try Device.insert { device }.execute(db)
}

/// `seedGrowableWorld`'s meshed hub with one surveyed, meshed, dense belt to
/// site a mine at — and no vessel any other goal would launch on.
private func seedMineWorld(_ db: Database) throws {
    try seedGrowableWorld(db, carriers: [], salvage: [:])
    try seedSystemDetail(
        db, system: mineHubSystem, scanned: true,
        belts: [Belt(designation: mineBelt, density: "dense")]
    )
}

private func mineDirectives(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in try Directive.all.fetchAll(db) }
}

/// One tick. `uuid` is a parameter so a test driving SEVERAL ticks can carry one
/// generator across them — a fresh `.incrementing` per tick reissues ids the
/// earlier tick already wrote, and the insert fails on the primary key.
private func mineTick(_ database: any DatabaseWriter, uuid: UUIDGenerator = .incrementing) async {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(mineNow)
        $0.uuid = uuid
    } operation: {
        _ = await Brain(now: mineNow).evaluateOnce()
    }
}

@Suite("Brain — ensureMine")
struct BrainEnsureMineTests {
    @Test func aFullBoardInsertsExactlyOneMineRun() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            for device in minePrintedFleet() + [mineCarrierDevice()] {
                try seedMineDevice(db, device)
            }
        }

        await mineTick(database)

        let directives = try await mineDirectives(database)
        let mine = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(mine.kind == .mineRun)
        #expect(mine.deviceCode == mineCarrier)
        #expect(mine.targets == [mineBelt])
        #expect(mine.fleetTag == MineRecipe.fleetTag)
        #expect(mine.step == MineRun().firstStep)
        #expect(mine.status == .running)
        #expect(mine.roamCentre == nil)
        #expect(mine.originDesignation == mineHubSystem)
    }

    @Test func aSecondTickWithTheRunStillLiveInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            for device in minePrintedFleet() + [mineCarrierDevice()] {
                try seedMineDevice(db, device)
            }
        }
        await mineTick(database)
        let afterFirst = try await mineDirectives(database)
        #expect(afterFirst.count == 1)

        await mineTick(database)

        #expect(try await mineDirectives(database) == afterFirst)
    }

    @Test func anIdleVerdictInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        // The ready world minus the printed fleet: nothing to install.
        try await database.write { db in
            try seedMineWorld(db)
            try seedMineDevice(db, mineCarrierDevice())
        }

        await mineTick(database)

        #expect(try await mineDirectives(database).isEmpty)
    }
}

@Suite("Brain — ensureMineFerries")
struct BrainEnsureMineFerriesTests {
    /// An installed mine: its mining controller stands at the belt, its
    /// transport controller waits at the hub.
    private func seedInstalledMine(
        _ db: Database, belt: String, controller: String, transport: String
    ) throws {
        try seedMineDevice(db, mineDevice(controller, type: "ami_mining_controller", location: belt))
        try seedMineDevice(db, mineDevice(transport, type: mineTransportType))
    }

    private func haulController(_ code: String) -> Device {
        mineDevice(
            code, type: mineTransportType, tags: [HaulRun.defaultFleetTag],
            directives: [HaulRun.requiredDirective]
        )
    }

    @Test func anInstalledMineGetsItsOwnRowBesideTheGeneralDrainer() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            try self.seedInstalledMine(db, belt: mineBelt, controller: "MC1", transport: "TC1")
            try seedMineDevice(db, self.haulController("T1"))
        }

        await mineTick(database)

        let hauls = try await mineDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 2)
        let ferry = try #require(hauls.first { !Brain.isGeneralHaul($0) })
        let general = try #require(hauls.first(where: Brain.isGeneralHaul))
        #expect(ferry.deviceCode == "TC1")
        #expect(ferry.targets == [mineBelt])
        #expect(ferry.step == HaulRun().firstStep)
        #expect(ferry.originDesignation == mineHubSystem)
        #expect(general.deviceCode == "T1")
        #expect(general.targets.isEmpty)
    }

    /// The stamp must land at LAUNCH: `assign`'s in-force short-circuit skips
    /// `.assignController` forever on a ferry the `mineRun` already armed, so
    /// the row would otherwise never own its controller and the built-in row
    /// would never lock. The reservation set is unchanged — `deviceCode`
    /// already reserves the same device.
    @Test func theFerryRowOwnsItsControllerFromLaunch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            try self.seedInstalledMine(db, belt: mineBelt, controller: "MC1", transport: "TC1")
        }

        await mineTick(database)

        let ferry = try #require(try await mineDirectives(database).first { $0.kind == .haulRun })
        #expect(ferry.controllerCode == "TC1")
        #expect(ferry.deviceCode == "TC1")
        let devices = try await database.read { db in try Device.all.fetchAll(db) }
        let byCode = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) })
        var unstamped = ferry
        unstamped.controllerCode = nil
        #expect(
            Brain.reservedDevices(directives: [ferry], devices: byCode)
                == Brain.reservedDevices(directives: [unstamped], devices: byCode)
        )
    }

    @Test func aSecondTickAddsNoSecondFerry() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            try self.seedInstalledMine(db, belt: mineBelt, controller: "MC1", transport: "TC1")
        }
        await mineTick(database)
        let afterFirst = try await mineDirectives(database)
        #expect(afterFirst.count == 1)

        await mineTick(database)

        #expect(try await mineDirectives(database) == afterFirst)
    }

    /// `installedBelts` reads true the moment the fleet stands away from the
    /// hub, which is BEFORE the run has armed the transport controller — so a
    /// ferry row launched then would command the controller the run is arming.
    @Test func aBeltALiveMineRunTargetsGetsNoFerry() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            try self.seedInstalledMine(db, belt: mineBelt, controller: "MC1", transport: "TC1")
            try seedDirective(
                db, id: "M1", kind: .mineRun, status: .running, deviceCode: mineCarrier,
                fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
            )
        }

        await mineTick(database)

        let hauls = try await mineDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.isEmpty)
    }

    @Test func theTickAfterTheMineRunFinishesLaunchesTheFerry() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            try self.seedInstalledMine(db, belt: mineBelt, controller: "MC1", transport: "TC1")
            try seedDirective(
                db, id: "M1", kind: .mineRun, status: .completed, deviceCode: mineCarrier,
                fleetTag: MineRecipe.fleetTag, targets: [mineBelt]
            )
        }

        await mineTick(database)

        let hauls = try await mineDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 1)
        #expect(hauls.first?.targets == [mineBelt])
        #expect(hauls.first?.deviceCode == "TC1")
    }

    /// Each mine drains through its OWN controller. A row whose fleet tag
    /// reserved the whole `auto:mine` fleet would make the second row
    /// impossible, so this is the assertion that pins the tag's scope.
    @Test func twoInstalledMinesEachGetTheirOwnFerry() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedMineWorld(db)
            try self.seedInstalledMine(db, belt: mineBelt, controller: "MC1", transport: "TC1")
            try self.seedInstalledMine(db, belt: "SOL-BELT-2", controller: "MC2", transport: "TC2")
        }

        // Two ticks: the first row reserves its controller, and the second belt
        // reads that reservation off the snapshot the NEXT tick takes.
        let uuid = UUIDGenerator.incrementing
        await mineTick(database, uuid: uuid)
        await mineTick(database, uuid: uuid)

        let hauls = try await mineDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 2)
        #expect(Set(hauls.flatMap(\.targets)) == [mineBelt, "SOL-BELT-2"])
        #expect(Set(hauls.map(\.deviceCode)) == ["TC1", "TC2"])
    }
}
