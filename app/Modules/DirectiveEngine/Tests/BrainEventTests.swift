//
//  BrainEventTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.eventReadiness` as a verdict table, and `ensureEvent`'s two leases.
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

// MARK: - Fixtures

private let eventDepot = "HUB-1"
private let eventTheatre = Theatre(
    depot: eventDepot, system: "HUB", origin: .derived, readiness: .operational, stock: 500_000
)

/// A hull of `type` standing at `eventDepot`. Every suite below seeds TWO of each
/// shape, so a selection assertion proves an ordering rather than a coincidence.
private func hull(
    _ code: String, type: String, tags: [String] = [], location: String? = eventDepot,
    status: String = "idle"
) -> Device {
    var device = EventRunFixtures.device(code, type: type, location: location, tags: tags)
    device.status = status
    return device
}

private func carrier(_ code: String, tags: [String] = [MineRecipe.carrierTag.string], location: String? = eventDepot, status: String = "idle") -> Device {
    hull(code, type: EventRun.carrierDeviceType, tags: tags, location: location, status: status)
}

private func freighter(_ code: String, location: String? = eventDepot, status: String = "idle") -> Device {
    hull(code, type: EventRun.freighterDeviceType, location: location, status: status)
}

/// A `matrix_container` at the depot wearing its print tag; `courierHosts` is
/// the other half of what makes it a courier.
private func courier(_ code: String, tags: [String] = [EventRun.rootTag.string]) -> Device {
    hull(code, type: EventRun.courierDeviceType, tags: tags)
}

/// `hull` with `units` already in its hold — the ordinary mid-cycle state of a
/// haul freighter standing at the depot between trips.
private func laden(_ hull: Device, units: Int) -> Device {
    var laden = hull
    laden.detail = .object([
        "cargo_used": .number(Double(units)), "cargo_capacity": .number(500),
    ])
    return laden
}

private func eventFixture(
    _ designation: String,
    location: String,
    tier: Int = 1,
    options: [String] = ["default"],
    chosen: String? = nil
) -> LocationEvent {
    LocationEvent(
        designation: designation, location: location, tier: tier, status: "active",
        detail: .object([
            "criteria": .array(options.map { name in
                .object([
                    "name": .string(name),
                    "devices": .array([]),
                    "resources": .object(["structural": .number(200)]),
                ])
            }),
            "rewards": .object(["xp": .number(500)]),
        ]),
        firstSeenAt: .distantPast, updatedAt: .distantPast, chosenOption: chosen
    )
}

private func eventView(
    devices: [Device], events: [LocationEvent], courierHosts: Set<String> = ["BOX"],
    bills: [String: ResourceCost] = [:], blueprintComponents: [String: [String: Int]] = [:]
) -> WorldView {
    WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: [
            "HUB": Position(x: 0, y: 0, z: 0),
            "X": Position(x: 1, y: 0, z: 0),
            "Y": Position(x: 2, y: 0, z: 0),
            "TABAT-4": Position(x: 3, y: 0, z: 0),
        ],
        meshSystems: ["HUB", "X", "Y", "TABAT-4"],
        salvageUnits: [:],
        eventSystems: Set(events.filter(\.isActive).map { SiteAssay.system(of: $0.location) }),
        theatres: [eventTheatre],
        replicantHostDevices: courierHosts,
        locationEvents: events,
        blueprintBills: bills,
        blueprintComponents: blueprintComponents,
        now: .distantPast
    )
}

/// The full board: a courier, two tagged carriers and two freighters.
private func stagedConvoy() -> [Device] {
    [
        courier("BOX"),
        carrier("CARRIER-A"), carrier("CARRIER-B"),
        freighter("FREIGHT-A"), freighter("FREIGHT-B"),
    ]
}

private func liveEventRun(
    id: String, carrier: String, freighters: [String], target: String,
    status: DirectiveStatus = .running
) -> Directive {
    Directive(
        id: id, kind: .eventRun, status: status, deviceCode: carrier,
        controllerCode: nil, roamCentre: nil,
        fleetTag: EventRun.fleetTag(forTheatre: eventDepot).string, sourceRelayCode: nil,
        targets: [target], targetIndex: 0, step: EventRun.Step.departing.rawValue,
        stepStartedAt: .distantPast, returnToOrigin: true, originDesignation: "HUB",
        attentionReason: nil, createdAt: .distantPast, updatedAt: .distantPast,
        theatreDepot: eventDepot, freighterCodes: freighters
    )
}

/// A row of another kind holding `code` and nothing else — the "some other goal
/// already spent this hull" shape.
private func holder(_ id: String, on code: String) -> Directive {
    Directive(
        id: id, kind: .relayRun, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: [], targetIndex: 0, step: "acquire", stepStartedAt: .distantPast,
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: .distantPast, updatedAt: .distantPast, theatreDepot: eventDepot
    )
}

// MARK: - eventReadiness

@Suite("Brain event readiness")
struct BrainEventReadinessTests {
    @Test("no courier is idle, never a stall")
    func noCourierIsIdle() {
        let devices = [
            carrier("CARRIER-A"), carrier("CARRIER-B"),
            freighter("FREIGHT-A"), freighter("FREIGHT-B"),
        ]
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [eventFixture("X-1-EVT-001", location: "X-1")]),
            directives: [], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("courier"))
    }

    @Test("a container hosting no replicant is not a courier")
    func unhostedContainerIsIdle() {
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(), events: [eventFixture("X-1-EVT-001", location: "X-1")],
                courierHosts: []
            ),
            directives: [], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("courier"))
    }

    @Test("the account's own anchor host is not read as a courier")
    func untaggedHostIsNotACourier() {
        var devices = stagedConvoy()
        devices[0] = courier("ANCHOR", tags: [])
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: devices, events: [eventFixture("X-1-EVT-001", location: "X-1")],
                courierHosts: ["ANCHOR"]
            ),
            directives: [], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("courier"))
    }

    @Test("a freighter still carrying someone's haul is never spent")
    func ladenFreighterIsNotSpent() {
        var devices = stagedConvoy()
        devices[3] = laden(freighter("FREIGHT-A"), units: 120)
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [eventFixture("X-1-EVT-001", location: "X-1")]),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(_, let freighters, _) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(freighters == ["FREIGHT-B"])
    }

    @Test("every freighter at the depot carrying cargo is idle, not a skipped collect")
    func everyFreighterLadenIsIdle() {
        var devices = stagedConvoy()
        devices[3] = laden(freighter("FREIGHT-A"), units: 120)
        devices[4] = laden(freighter("FREIGHT-B"), units: 473)
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [eventFixture("X-1-EVT-001", location: "X-1")]),
            directives: [], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("empty hold"))
    }

    @Test("a staged convoy and a ranked event launches the lowest free hull of each type")
    func launches() {
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(), events: [eventFixture("X-1-EVT-001", location: "X-1")]
            ),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(let carrier, let freighters, let candidate) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(carrier == "CARRIER-A")
        #expect(freighters == ["FREIGHT-A"])
        #expect(candidate.designation == "X-1-EVT-001")
        #expect(candidate.option.name == "default")
    }

    /// A SCOPED-tag lease binds only its own theatre, so a freighter another
    /// theatre's row sweeps is still this one's to spend. `freeHull` applies no
    /// tag filter at all here, so nothing else separates the two.
    @Test("a freighter held by another theatre's scoped tag is still spendable here")
    func aScopedLeaseElsewhereLeavesTheFreighterSpendable() {
        var tagged = freighter("FREIGHT-A")
        tagged.tags = ["auto:haul:FAR-1"]
        let view = eventView(
            devices: [courier("BOX"), carrier("CARRIER-A"), tagged],
            events: [eventFixture("X-1-EVT-001", location: "X-1")]
        )
        let elsewhere = Directive(
            id: "H1", kind: .haulRun, status: .running, deviceCode: "FAR-CONTROLLER",
            controllerCode: nil, roamCentre: nil, fleetTag: "auto:haul:FAR-1",
            sourceRelayCode: nil, targets: [], targetIndex: 0, step: "assigning",
            stepStartedAt: .distantPast, returnToOrigin: false, originDesignation: nil,
            attentionReason: nil, createdAt: .distantPast, updatedAt: .distantPast,
            theatreDepot: "FAR-1"
        )
        #expect(
            Brain.reservedDevices(directives: [elsewhere], devices: view.devices).contains("FREIGHT-A")
        )
        let readiness = Brain.eventReadiness(
            view: view, directives: [elsewhere], theatre: eventTheatre
        )
        guard case .launch(_, let freighters, _) = readiness else {
            Issue.record("expected .launch, got \(readiness)"); return
        }
        #expect(freighters == ["FREIGHT-A"])
    }

    @Test("an untagged surge carrier is never spent")
    func untaggedCarrierIsNotSpent() {
        var devices = stagedConvoy()
        devices[1] = carrier("CARRIER-A", tags: [])
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [eventFixture("X-1-EVT-001", location: "X-1")]),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(let carrier, let freighters, _) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(carrier == "CARRIER-B")
        #expect(freighters == ["FREIGHT-A"])
    }

    @Test("a hull standing somewhere else is never spent")
    func offDepotHullIsNotSpent() {
        var devices = stagedConvoy()
        devices[1] = carrier("CARRIER-A", location: "OTHER-1")
        devices[3] = freighter("FREIGHT-A", location: nil)
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [eventFixture("X-1-EVT-001", location: "X-1")]),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(let carrier, let freighters, _) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(carrier == "CARRIER-B")
        #expect(freighters == ["FREIGHT-B"])
    }

    @Test("a hull mid-activity is never spent")
    func busyHullIsNotSpent() {
        var devices = stagedConvoy()
        devices[1] = carrier("CARRIER-A", status: "travelling")
        devices[3] = freighter("FREIGHT-A", status: "printing")
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [eventFixture("X-1-EVT-001", location: "X-1")]),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(let carrier, let freighters, _) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(carrier == "CARRIER-B")
        #expect(freighters == ["FREIGHT-B"])
    }

    @Test("a live run's event, carrier and freighter are all excluded at once")
    func liveRunExcludesEveryLeaseItHolds() {
        let live = liveEventRun(
            id: "d1", carrier: "CARRIER-A", freighters: ["FREIGHT-A"], target: "X-1-EVT-001"
        )
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(),
                events: [
                    eventFixture("X-1-EVT-001", location: "X-1"),
                    eventFixture("Y-1-EVT-002", location: "Y-1"),
                ]
            ),
            directives: [live], theatre: eventTheatre
        )
        guard case .launch(let carrier, let freighters, let candidate) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(carrier == "CARRIER-B")
        #expect(freighters == ["FREIGHT-B"])
        #expect(candidate.designation == "Y-1-EVT-002")
    }

    @Test("an event a live run already targets is not re-launched")
    func excludesLiveTarget() {
        let live = liveEventRun(
            id: "d1", carrier: "CARRIER-A", freighters: ["FREIGHT-A"], target: "X-1-EVT-001"
        )
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(), events: [eventFixture("X-1-EVT-001", location: "X-1")]
            ),
            directives: [live], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("no event worth working"))
    }

    @Test("a halted run still owns its convoy")
    func haltedRunStillHoldsItsLeases() {
        let live = liveEventRun(
            id: "d1", carrier: "CARRIER-A", freighters: ["FREIGHT-A"], target: "X-1-EVT-001",
            status: .needsAttention
        )
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(),
                events: [
                    eventFixture("X-1-EVT-001", location: "X-1"),
                    eventFixture("Y-1-EVT-002", location: "Y-1"),
                ]
            ),
            directives: [live], theatre: eventTheatre
        )
        guard case .launch(let carrier, let freighters, _) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(carrier == "CARRIER-B")
        #expect(freighters == ["FREIGHT-B"])
    }

    @Test("every carrier held is idle, naming the carrier")
    func everyCarrierHeldIsIdle() {
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(), events: [eventFixture("X-1-EVT-001", location: "X-1")]
            ),
            directives: [holder("h1", on: "CARRIER-A"), holder("h2", on: "CARRIER-B")],
            theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("surge carrier"))
    }

    @Test("every freighter held is idle, naming the freighter")
    func everyFreighterHeldIsIdle() {
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(), events: [eventFixture("X-1-EVT-001", location: "X-1")]
            ),
            directives: [holder("h1", on: "FREIGHT-A"), holder("h2", on: "FREIGHT-B")],
            theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("cargo freighter"))
    }

    @Test("a multi-option event the operator has not decided is never launched")
    func multiOptionEventIsNotLaunched() {
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(),
                events: [eventFixture("X-1-EVT-001", location: "X-1", options: ["satellite", "booster"])]
            ),
            directives: [], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("no event worth working"))
    }

    /// The undecided event outranks on tier, so admitting it would park the only
    /// convoy behind an unanswered question instead of working the backlog.
    @Test("an undecided event is skipped, not preferred, however it ranks")
    func multiOptionEventIsSkippedForADecidedOne() {
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(),
                events: [
                    eventFixture("X-1-EVT-001", location: "X-1", tier: 5, options: ["satellite", "booster"]),
                    eventFixture("Y-1-EVT-002", location: "Y-1", tier: 1),
                ]
            ),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(_, _, let candidate) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(candidate.designation == "Y-1-EVT-002")
    }

    /// The pick is read off each event's own column — an empty map would leave
    /// this decided event unworkable forever.
    @Test("a recorded choice makes a multi-option event workable")
    func recordedChoiceIsRead() {
        let readiness = Brain.eventReadiness(
            view: eventView(
                devices: stagedConvoy(),
                events: [
                    eventFixture(
                        "X-1-EVT-001", location: "X-1", options: ["satellite", "booster"],
                        chosen: "booster"
                    )
                ]
            ),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(_, _, let candidate) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(candidate.designation == "X-1-EVT-001")
        #expect(candidate.option.name == "booster")
    }

    @Test("a closed event is never worked")
    func inactiveEventIsIdle() {
        var closed = eventFixture("X-1-EVT-001", location: "X-1")
        closed.status = "completed"
        let readiness = Brain.eventReadiness(
            view: eventView(devices: stagedConvoy(), events: [closed]),
            directives: [], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason == "no event worth working")
    }

    @Test("the brain will not launch a run for an event it cannot build")
    func blockedEventNeverLaunches() throws {
        let event = LocationEvent(
            designation: "TABAT-4-EVT-007", location: "TABAT-4", tier: 4, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("only"),
                    "devices": .array([.object([
                        "count": .number(2), "device_type": .string("climate_processor"),
                    ])]),
                    "resources": .object([:]),
                ])]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let view = eventView(
            devices: stagedConvoy(), events: [event],
            bills: ["climate_processor": ResourceCost(structural: 200)],
            blueprintComponents: ["climate_processor": ["orbital_mirror": 1]]
        )
        guard case .idle(let reason) = Brain.eventReadiness(
            view: view, directives: [], theatre: eventTheatre
        ) else { Issue.record("expected .idle for an unbuildable event"); return }
        #expect(reason == "no event worth working")
    }
}

// MARK: - Reservation

@Suite("Brain event lease reservation")
struct BrainEventReservationTests {
    @Test("a live run's freighter is reserved beside its carrier")
    func freighterIsReserved() {
        let devices = Dictionary(
            uniqueKeysWithValues: [
                carrier("CARRIER-A"), carrier("CARRIER-B"),
                freighter("FREIGHT-A"), freighter("FREIGHT-B"),
            ].map { ($0.deviceCode, $0) }
        )
        let reserved = Brain.reservedDevices(
            directives: [
                liveEventRun(
                    id: "d1", carrier: "CARRIER-A", freighters: ["FREIGHT-A"], target: "X-1-EVT-001"
                )
            ],
            devices: devices
        )
        #expect(reserved == ["CARRIER-A", "FREIGHT-A"])
    }

    @Test("a finished run's freighter is released")
    func finishedRunReleasesItsFreighter() {
        let devices = Dictionary(
            uniqueKeysWithValues: [carrier("CARRIER-A"), freighter("FREIGHT-A")]
                .map { ($0.deviceCode, $0) }
        )
        let reserved = Brain.reservedDevices(
            directives: [
                liveEventRun(
                    id: "d1", carrier: "CARRIER-A", freighters: ["FREIGHT-A"],
                    target: "X-1-EVT-001", status: .completed
                )
            ],
            devices: devices
        )
        #expect(reserved.isEmpty)
    }

    @Test("an event run is brain-managed, so its retry-classified stall auto-retries")
    func eventRunJoinsTheBrainManagedSet() {
        #expect(Brain.brainManagedKinds.contains(.eventRun))
        #expect(!Brain.brainManagedKinds.contains(.eventCourierPrint))

        var stalled = liveEventRun(
            id: "d1", carrier: "CARRIER-A", freighters: ["FREIGHT-A"], target: "X-1-EVT-001",
            status: .needsAttention
        )
        stalled.attentionReason = .eventCommitRejected
        #expect(Brain.brainManagedStall(stalled) == .eventCommitRejected)
        guard case .retry = Brain.stallResponse(for: stalled, log: [], now: .distantPast) else {
            Issue.record("expected .retry"); return
        }
    }
}

// MARK: - ensureEvent

private let eventNow = Date(timeIntervalSince1970: 9_000)
private let eventSystem = "VEGA"
private let eventDesignation = "VEGA-1-EVT-001"

/// `seedGrowableWorld`'s meshed hub, a courier hosting a replicant, and two of
/// every hull the convoy leases — so a launch assertion names an ordering. The
/// event's system is MESHED, or its value is grow demand and restock launches too.
private func seedEventWorld(_ db: Database) throws {
    try seedGrowableWorld(db, carriers: [], salvage: [:])
    try seedStar(db, designation: eventSystem, x: 4, y: 0, z: 0)
    try seedRelay(db, code: "REL2", location: eventSystem)
    try Device.insert {
        deviceFixture(
            code: "BOX", type: EventRun.courierDeviceType, location: growHubLocation,
            features: [], tags: [EventRun.rootTag.string], updatedAt: eventNow
        )
    }.execute(db)
    try seedReplicant(db, code: "R-COURIER", star: "SOL", hostedDeviceCode: "BOX")
    for code in ["CARRIER-A", "CARRIER-B"] {
        try seedDevice(
            db, code: code, type: EventRun.carrierDeviceType, location: growHubLocation,
            features: carrierHullFeatures, tags: [MineRecipe.carrierTag.string], updatedAt: eventNow
        )
    }
    for code in ["FREIGHT-A", "FREIGHT-B"] {
        try seedDevice(
            db, code: code, type: EventRun.freighterDeviceType, location: growHubLocation,
            features: [], updatedAt: eventNow
        )
    }
    try LocationEvent.insert {
        eventFixture(eventDesignation, location: "\(eventSystem)-1")
    }.execute(db)
}

private func eventDirectives(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in try Directive.all.fetchAll(db) }
}

private func eventTick(_ database: any DatabaseWriter, uuid: UUIDGenerator = .incrementing) async {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(eventNow)
        $0.uuid = uuid
    } operation: {
        _ = await Brain(now: eventNow).evaluateOnce()
    }
}

@Suite("Brain — ensureEvent")
struct BrainEnsureEventTests {
    @Test func aFullBoardInsertsExactlyOneEventRun() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedEventWorld(db) }

        await eventTick(database)

        let directives = try await eventDirectives(database)
        let run = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(run.kind == .eventRun)
        #expect(run.deviceCode == "CARRIER-A")
        #expect(run.freighterCodes == ["FREIGHT-A"])
        #expect(run.targets == [eventDesignation])
        #expect(run.fleetTag == EventRun.fleetTag(forTheatre: growHubLocation).string)
        #expect(run.step == EventRun().firstStep)
        #expect(run.status == .running)
        #expect(run.returnToOrigin)
        #expect(run.theatreDepot == growHubLocation)
        #expect(run.originDesignation == "SOL")
    }

    @Test func aSecondTickWithTheRunStillLiveInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedEventWorld(db) }
        await eventTick(database)
        let afterFirst = try await eventDirectives(database)
        #expect(afterFirst.count == 1)

        await eventTick(database)

        #expect(try await eventDirectives(database) == afterFirst)
    }

    @Test func noCourierInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedEventWorld(db)
            try Device.delete().where { $0.deviceCode.eq("BOX") }.execute(db)
        }

        await eventTick(database)

        #expect(try await eventDirectives(database).isEmpty)
    }
}

// MARK: - ensureOne's second lease

@Suite("Brain — ensureOne freighter lease")
struct BrainEnsureOneFreighterTests {
    /// A snapshot with no directives at all, standing in for the stale read a
    /// tick's own earlier launches have already invalidated.
    private func staleSnapshot() -> Brain.Snapshot {
        Brain.Snapshot(
            view: eventView(
                devices: stagedConvoy(), events: [eventFixture("X-1-EVT-001", location: "X-1")]
            ),
            directives: [], log: [:], hubStocks: [:]
        )
    }

    private func seedHulls(_ db: Database) throws {
        for device in stagedConvoy() {
            try Device.insert { device }.execute(db)
        }
    }

    private func run(freighter: String) -> Directive {
        liveEventRun(
            id: "new", carrier: "CARRIER-B", freighters: [freighter], target: "X-1-EVT-001"
        )
    }

    @Test("a freighter another row already holds is not committed")
    func declinesACommittedFreighter() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedHulls(db)
            try Directive.insert { holder("h1", on: "FREIGHT-A") }.execute(db)
        }

        let directive = run(freighter: "FREIGHT-A")
        await Brain(now: eventNow).ensureOne(
            .eventRun, theatre: eventTheatre, snapshot: staleSnapshot(), database: database
        ) { directive }

        let rows = try await eventDirectives(database)
        #expect(rows.map(\.id) == ["h1"])
    }

    @Test("a free freighter is committed")
    func admitsAFreeFreighter() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedHulls(db)
            try Directive.insert { holder("h1", on: "FREIGHT-A") }.execute(db)
        }

        let directive = run(freighter: "FREIGHT-B")
        await Brain(now: eventNow).ensureOne(
            .eventRun, theatre: eventTheatre, snapshot: staleSnapshot(), database: database
        ) { directive }

        let rows = try await eventDirectives(database)
        #expect(rows.map(\.id).sorted() == ["h1", "new"])
    }
}

/// A payload wider than one hold: the brain leases a freighter per hold, and
/// idles rather than launching a convoy that could never finish the delivery.
@Suite("Brain — leasing enough hold")
struct BrainEventHoldTests {
    /// 800 units against the 500-unit holds every cargo freighter reports.
    private func megaproject() -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 3, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("default"), "devices": .array([]),
                    "resources": .object(["carbon": .number(600), "conductive": .number(200)]),
                ])]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    private func emptyHold(_ code: String) -> Device { laden(freighter(code), units: 0) }

    @Test("an 800-unit payload leases two 500-unit holds")
    func leasesTwoHolds() {
        let devices = [courier("BOX"), carrier("CARRIER-A"), emptyHold("FREIGHT-A"), emptyHold("FREIGHT-B")]
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [megaproject()]),
            directives: [], theatre: eventTheatre
        )
        guard case .launch(_, let freighters, _) = readiness else {
            Issue.record("expected .launch, got \(readiness)"); return
        }
        #expect(freighters == ["FREIGHT-A", "FREIGHT-B"])
    }

    @Test("one hold short of the payload idles rather than launching")
    func idlesWhenTheHoldIsShort() {
        let devices = [courier("BOX"), carrier("CARRIER-A"), emptyHold("FREIGHT-A")]
        let readiness = Brain.eventReadiness(
            view: eventView(devices: devices, events: [megaproject()]),
            directives: [], theatre: eventTheatre
        )
        guard case .idle(let reason) = readiness else {
            Issue.record("expected .idle, got \(readiness)"); return
        }
        #expect(reason.contains("800 units"))
    }
}
