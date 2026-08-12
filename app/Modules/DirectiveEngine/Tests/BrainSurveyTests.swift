//
//  BrainSurveyTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.surveyReadiness` as a pure function table: every gate names the
//  reason it declined rather than a bare "not ready", and an unstaged vessel
//  must idle — never reach the mission and manufacture a stall. The second
//  suite below drives `Brain.ensureSurvey` end to end through a real database.
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

private let surveyFixtureNow = Date(timeIntervalSince1970: 5_000)

/// A device for the readiness fixtures below. `directives:` feeds
/// `available_directives`, the runtime source `Device.availableDirectives`
/// reads first.
private func surveyReadinessDevice(
    _ code: String,
    type: String,
    tags: [String] = [],
    location: String? = nil,
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
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: fixtureFeatures(for: type), tags: tags,
        detail: .object(detail),
        updatedAt: surveyFixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func surveyReadinessView(
    devices: [Device],
    depot: String? = nil,
    starPositions: [String: Position] = [:]
) -> WorldView {
    let theatre = singleOperationalTheatre(depot: depot)
    return WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: starPositions,
        meshSystems: [],
        salvageUnits: [:],
        eventSystems: [],
        theatres: theatre.theatres,
        components: theatre.components,
        now: surveyFixtureNow
    )
}

/// A fully staged survey vessel: tagged, a controller stowed aboard offering
/// `survey_system`, and one drone the controller has adopted, also aboard.
/// `location` is what `Brain.owningTheatre` resolves the carrier through.
private func surveyReadinessStagedFleet(
    carrier: String = "V1", controller: String = "AMI1", drone: String = "DRONE1",
    location: String? = "AINALRAM-1", tags: [String] = [Brain.surveyCarrierTag]
) -> [Device] {
    [
        surveyReadinessDevice(carrier, type: "heaven_vessel", tags: tags, location: location),
        surveyReadinessDevice(
            controller, type: "ami_survey_controller", stowedIn: carrier, directives: ["survey_system"]
        ),
        surveyReadinessDevice(drone, type: "survey_drone", stowedIn: carrier, controllerDeviceCode: controller),
    ]
}

/// Two independent theatres in separate mesh components, each carrying the
/// given fleet's devices at its own system. Component separation makes
/// `owningTheatre` resolve each fleet to its own theatre unambiguously.
private func twoTheatreSurveyView(
    ainalramFleet: [Device], denebedFleet: [Device]
) -> (view: WorldView, ainalram: Theatre, denebed: Theatre) {
    let ainalram = Theatre(
        depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived, readiness: .operational, stock: 0
    )
    let denebed = Theatre(
        depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned, readiness: .operational, stock: 0
    )
    let devices = ainalramFleet + denebedFleet
    let view = WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0), "DENEBED": Position(x: 100, y: 100, z: 100)],
        meshSystems: [],
        salvageUnits: [:],
        eventSystems: [],
        theatres: [ainalram, denebed],
        components: ["AINALRAM": "AINALRAM", "DENEBED": "DENEBED"],
        now: surveyFixtureNow
    )
    return (view, ainalram, denebed)
}

/// The single-theatre fixtures' theatre — depot `AINALRAM-BELT-1`, matching
/// `surveyReadinessView(depot:)`'s default single-theatre setup.
private let ainalramTheatre = Theatre(
    depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived, readiness: .operational, stock: 0
)

@Suite("Brain — the survey readiness verdict")
struct BrainSurveyTests {
    @Test("a tagged, staged fleet with a census-known anchor system is ready to launch")
    func readyToLaunch() {
        let view = surveyReadinessView(
            devices: surveyReadinessStagedFleet(),
            depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        #expect(Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre) == .launch(carrier: "V1", roamCentre: "AINALRAM"))
    }

    @Test("no vessel tagged auto:survey idles, naming the tag")
    func untaggedFleetIdles() {
        let devices = [surveyReadinessDevice("V1", type: "heaven_vessel", location: "AINALRAM-1")]
        let view = surveyReadinessView(
            devices: devices, depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason.contains(Brain.surveyCarrierTag))
        #expect(reason.contains("V1"))
    }

    @Test("a tagged vessel with no survey controller aboard idles, never stalls")
    func noControllerAboardIdles() {
        let devices = [
            surveyReadinessDevice("V1", type: "heaven_vessel", tags: [Brain.surveyCarrierTag], location: "AINALRAM-1"),
        ]
        let view = surveyReadinessView(
            devices: devices, depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre) else {
            Issue.record("expected idle, never a stall")
            return
        }
        #expect(reason.contains("V1"))
        #expect(reason.contains("controller"))
    }

    @Test("a tagged vessel whose controller has adopted no drone aboard idles, naming that")
    func noAdoptedDroneAboardIdles() {
        let devices = [
            surveyReadinessDevice("V1", type: "heaven_vessel", tags: [Brain.surveyCarrierTag], location: "AINALRAM-1"),
            surveyReadinessDevice(
                "AMI1", type: "ami_survey_controller", stowedIn: "V1", directives: ["survey_system"]
            ),
        ]
        let view = surveyReadinessView(
            devices: devices, depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason.contains("V1"))
        #expect(reason.contains("AMI1"))
        #expect(reason.contains("drone"))
    }

    /// `surveyReadiness` takes an arbitrary `Theatre` — one whose `system`
    /// disagrees with its own `depot`'s real system still resolves a carrier
    /// (matched on depot), so this seam can still reach the census guard.
    @Test("a roam centre the census does not know idles, naming it")
    func unknownRoamCentreIdles() {
        let view = surveyReadinessView(
            devices: surveyReadinessStagedFleet(),
            depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )
        let mismatchedTheatre = Theatre(
            depot: "AINALRAM-BELT-1", system: "GHOST", origin: .derived, readiness: .operational, stock: 0
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: mismatchedTheatre) else {
            Issue.record("expected idle — SurveyRun.plan would exhaust immediately")
            return
        }
        #expect(reason.contains("GHOST"))
    }

    /// Untagged hulls and a misapplied tag are different remedies; the reason
    /// must carry both so neither hides the other.
    @Test("untagged hulls and a mistagged device are both named")
    func untaggedHullsAndMistaggedDeviceAreBothNamed() {
        let devices = [
            surveyReadinessDevice("V1", type: "heaven_vessel", location: "AINALRAM-1"),
            surveyReadinessDevice("P1", type: "propulsor", tags: [Brain.surveyCarrierTag]),
        ]
        let view = surveyReadinessView(
            devices: devices, depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason.contains("V1"))
        #expect(reason.contains("untagged"))
        #expect(reason.contains("P1 is tagged \(Brain.surveyCarrierTag) but is not a carrier hull"))
    }

    /// The no-hull sentence states existence and tagging, never a freedom
    /// test the survey gate does not run.
    @Test("a mistagged-only fleet names the device, not a freedom test")
    func mistaggedOnlyFleetNamesTheDevice() {
        let devices = [surveyReadinessDevice("P1", type: "propulsor", tags: [Brain.surveyCarrierTag])]
        let view = surveyReadinessView(
            devices: devices, depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason == "no carrier hull — P1 is tagged \(Brain.surveyCarrierTag) but is not a carrier hull")
    }

    /// The carrier gate is capability, not type: a staged `racing_vessel`
    /// wearing the survey tag must be exactly as flyable as a HEAVEN vessel.
    @Test("a tagged, staged racing vessel is a survey carrier")
    func racingVesselIsASurveyCarrier() {
        let devices = [
            surveyReadinessDevice("V1", type: "racing_vessel", tags: [Brain.surveyCarrierTag], location: "AINALRAM-1"),
            surveyReadinessDevice(
                "AMI1", type: "ami_survey_controller", stowedIn: "V1", directives: ["survey_system"]
            ),
            surveyReadinessDevice("DRONE1", type: "survey_drone", stowedIn: "V1", controllerDeviceCode: "AMI1"),
        ]
        let view = surveyReadinessView(
            devices: devices, depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        #expect(Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre) == .launch(carrier: "V1", roamCentre: "AINALRAM"))
    }

    /// Two theatres, each with its own tagged, staged carrier: each launches
    /// naming its OWN carrier and its OWN system, never the other's.
    @Test("two operational theatres each launch on their own carrier")
    func twoTheatresEachLaunchOnTheirOwnCarrier() {
        let (view, ainalram, denebed) = twoTheatreSurveyView(
            ainalramFleet: surveyReadinessStagedFleet(carrier: "VA", controller: "AMIA", drone: "DRONEA", location: "AINALRAM-1"),
            denebedFleet: surveyReadinessStagedFleet(carrier: "VB", controller: "AMIB", drone: "DRONEB", location: "DENEBED-1")
        )

        #expect(Brain.surveyReadiness(view: view, directives: [], theatre: ainalram) == .launch(carrier: "VA", roamCentre: "AINALRAM"))
        #expect(Brain.surveyReadiness(view: view, directives: [], theatre: denebed) == .launch(carrier: "VB", roamCentre: "DENEBED"))
    }

    /// A theatre with no carrier of its own idles, and must not call
    /// AINALRAM's tagged, staged `VA` untagged just because DENEBED can't
    /// see it.
    @Test("a theatre with no carrier of its own idles without consuming the other theatre's carrier")
    func theatreWithNoOwnCarrierIdlesWithoutConsumingTheOther() {
        let (view, ainalram, denebed) = twoTheatreSurveyView(
            ainalramFleet: surveyReadinessStagedFleet(carrier: "VA", controller: "AMIA", drone: "DRONEA", location: "AINALRAM-1"),
            denebedFleet: []
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: denebed) else {
            Issue.record("expected DENEBED to idle — it owns no carrier")
            return
        }
        #expect(reason == "no vessel is tagged \(Brain.surveyCarrierTag)")
        #expect(!reason.contains("VA"))
        #expect(Brain.surveyReadiness(view: view, directives: [], theatre: ainalram) == .launch(carrier: "VA", roamCentre: "AINALRAM"))
    }

    /// The mistagged clause stays fleet-wide even where carrier selection is
    /// theatre-scoped — a stowed device has no location, so `owningTheatre`
    /// can't place it in ANY theatre's pool, AINALRAM's included.
    @Test("a location-less mistagged device is still named in a multi-theatre world")
    func locationlessMistaggedDeviceIsStillNamedAcrossTheatres() {
        let (view, ainalram, _) = twoTheatreSurveyView(
            ainalramFleet: [surveyReadinessDevice("P1", type: "propulsor", tags: [Brain.surveyCarrierTag])],
            denebedFleet: []
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: ainalram) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason.contains("P1 is tagged \(Brain.surveyCarrierTag) but is not a carrier hull"))
    }

    // MARK: - Per-theatre fleet tags

    /// The headline shape at the pure-function level: two theatres, each with
    /// its own PER-THEATRE-tagged (already migrated) carrier, each launch on
    /// their own — never the bare tag.
    @Test("two theatres each with their own per-theatre-tagged carrier each launch their own")
    func twoTheatresEachWithAPerTheatreTaggedCarrierEachLaunchTheirOwn() {
        let (view, ainalram, denebed) = twoTheatreSurveyView(
            ainalramFleet: surveyReadinessStagedFleet(
                carrier: "VA", controller: "AMIA", drone: "DRONEA", location: "AINALRAM-1",
                tags: ["auto:survey:AINALRAM-BELT-1"]
            ),
            denebedFleet: surveyReadinessStagedFleet(
                carrier: "VB", controller: "AMIB", drone: "DRONEB", location: "DENEBED-1",
                tags: ["auto:survey:DENEBED-BELT-1"]
            )
        )

        #expect(Brain.surveyReadiness(view: view, directives: [], theatre: ainalram) == .launch(carrier: "VA", roamCentre: "AINALRAM"))
        #expect(Brain.surveyReadiness(view: view, directives: [], theatre: denebed) == .launch(carrier: "VB", roamCentre: "DENEBED"))
    }

    /// A carrier tagged for AINALRAM alone is never a candidate for DENEBED —
    /// the theatre it wears no tag for idles, naming no carrier at all.
    @Test("a device tagged for one theatre is not selected for another")
    func aDeviceTaggedForOneTheatreIsNotSelectedForAnother() {
        let (view, _, denebed) = twoTheatreSurveyView(
            ainalramFleet: surveyReadinessStagedFleet(
                carrier: "VA", controller: "AMIA", drone: "DRONEA", location: "AINALRAM-1",
                tags: ["auto:survey:AINALRAM-BELT-1"]
            ),
            denebedFleet: []
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [], theatre: denebed) else {
            Issue.record("expected DENEBED to idle — VA wears only AINALRAM's tag")
            return
        }
        #expect(!reason.contains("VA"))
    }

    /// The pure-function proof of the un-migrated warning: DENEBED's only
    /// candidate is bare-tagged and reserved by AINALRAM's legacy bare-tagged
    /// live run — the idle reason must name it and point at re-tagging.
    @Test("a candidate reserved by another theatre's legacy bare tag is named, not silently idle")
    func aCandidateReservedByAnotherTheatresLegacyTagIsNamed() {
        let (view, ainalram, denebed) = twoTheatreSurveyView(
            ainalramFleet: surveyReadinessStagedFleet(carrier: "VA", location: "AINALRAM-1"),
            denebedFleet: surveyReadinessStagedFleet(
                carrier: "VB", controller: "AMIB", drone: "DRONEB", location: "DENEBED-1"
            )
        )
        let live = directiveFixture(
            id: "LIVE", kind: .surveyRun, deviceCode: "VA",
            fleetTag: SurveyRun.defaultFleetTag, theatreDepot: ainalram.depot
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view, directives: [live], theatre: denebed) else {
            Issue.record("expected DENEBED to idle — VB is swept by AINALRAM's bare-tag reservation")
            return
        }
        #expect(reason.contains("VB"))
        #expect(reason.contains("re-tag"))
    }
}

// MARK: - `Brain.surveyStatus` — the why-view's verdict

@Suite("Brain — the survey status for the why-view")
struct BrainSurveyStatusTests {
    /// A live row wins outright — its OWN carrier and roam centre, never
    /// re-derived from `surveyReadiness`, and asked before that verdict is
    /// even computed.
    @Test("a live survey reports launched, off the row itself")
    func aLiveSurveyReportsLaunched() {
        let live = Directive(
            id: "LIVE", kind: .surveyRun, status: .running, deviceCode: "V9",
            roamCentre: "VEGA", targets: [], targetIndex: 0, step: "step",
            stepStartedAt: surveyFixtureNow, returnToOrigin: false, originDesignation: nil,
            attentionReason: nil, createdAt: surveyFixtureNow, updatedAt: surveyFixtureNow
        )
        // A view that would otherwise idle — proves the live row is checked
        // FIRST, not merely that it wins when readiness also says launch.
        let view = surveyReadinessView(devices: [], depot: nil)

        #expect(
            Brain.surveyStatus(directives: [live], view: view)
                == .launched(carrier: "V9", roamCentre: "VEGA", status: .running)
        )
    }

    /// A fixed-target run's row carries no `roamCentre` — `nil`, never a
    /// substitute string. The status field carries the row's own status too,
    /// so a halted or paused run is never silently reported as running.
    @Test("a fixed-target live survey carries its nil roam centre and real status through", arguments: [
        (DirectiveStatus.running, BrainSurveyStatus.LaunchedStatus.running),
        (.needsAttention, .needsAttention),
        (.paused, .paused),
    ])
    func aFixedTargetLiveSurveyCarriesNilCentreAndRealStatus(
        row: DirectiveStatus, expected: BrainSurveyStatus.LaunchedStatus
    ) {
        let live = Directive(
            id: "LIVE", kind: .surveyRun, status: row, deviceCode: "V9",
            roamCentre: nil, targets: ["ALTAIR"], targetIndex: 0, step: "step",
            stepStartedAt: surveyFixtureNow, returnToOrigin: false, originDesignation: nil,
            attentionReason: nil, createdAt: surveyFixtureNow, updatedAt: surveyFixtureNow
        )
        let view = surveyReadinessView(devices: [], depot: nil)

        #expect(
            Brain.surveyStatus(directives: [live], view: view)
                == .launched(carrier: "V9", roamCentre: nil, status: expected)
        )
    }

    /// No live row, and readiness says go: `.ready`, carrying the exact
    /// carrier/centre the launch below would use.
    @Test("a ready, staged fleet with no live row reports ready")
    func aReadyFleetReportsReady() {
        let view = surveyReadinessView(
            devices: surveyReadinessStagedFleet(),
            depot: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )
        #expect(
            Brain.surveyStatus(directives: [], view: view)
                == .ready(carrier: "V1", roamCentre: "AINALRAM")
        )
    }

    /// No live row, and readiness declines: the reason is carried straight
    /// through, unparaphrased.
    @Test("an unready fleet with no live row reports idle with the named reason")
    func anUnreadyFleetReportsIdle() {
        let devices = [surveyReadinessDevice("V1", type: "heaven_vessel")]
        let view = surveyReadinessView(devices: devices, depot: "AINALRAM-BELT-1")

        guard case let .idle(status) = Brain.surveyStatus(directives: [], view: view),
              case let .idle(readiness) = Brain.surveyReadiness(view: view, directives: [], theatre: ainalramTheatre)
        else {
            Issue.record("expected both to idle")
            return
        }
        #expect(status == readiness)
    }

    /// `surveyReadiness` takes its theatre as a parameter, so a world with no
    /// operational theatre at all is a `surveyStatus`-only concern.
    @Test("no operational theatre reports idle, naming that")
    func noOperationalTheatreReportsIdle() {
        let view = surveyReadinessView(devices: [], depot: nil)
        #expect(Brain.surveyStatus(directives: [], view: view) == .idle(reason: "no operational theatre"))
    }
}

// MARK: - `Brain.ensureSurvey`

private let surveyEnsureNow = Date(timeIntervalSince1970: 20_000)
private let surveyEnsureHubSystem = "SOL"
private let surveyEnsureCarrier = "SV1"

/// The DB-backed twin of `surveyReadinessDevice` above — same shape, written
/// straight to the database rather than held as a value.
private func seedSurveyEnsureDevice(
    _ db: Database, code: String, type: String, tags: [String] = [], location: String? = nil,
    stowedIn: String? = nil, controllerDeviceCode: String? = nil, directives: [String] = []
) throws {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    try Device.insert {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: fixtureFeatures(for: type), tags: tags,
            detail: .object(detail),
            updatedAt: surveyEnsureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

/// A fully staged, tagged survey fleet: `seedSurveyEnsureDevice`'s three rows,
/// carrier + stowed controller + adopted drone, standing at `location` —
/// what `owningTheatre` resolves the carrier through.
private func seedSurveyEnsureFleet(
    _ db: Database, carrier: String = surveyEnsureCarrier,
    controller: String = "AMI1", drone: String = "DRONE1", location: String = growHubLocation
) throws {
    try seedSurveyEnsureDevice(
        db, code: carrier, type: "heaven_vessel", tags: [Brain.surveyCarrierTag], location: location
    )
    try seedSurveyEnsureDevice(
        db, code: controller, type: "ami_survey_controller", stowedIn: carrier, directives: ["survey_system"]
    )
    try seedSurveyEnsureDevice(
        db, code: drone, type: "survey_drone", stowedIn: carrier, controllerDeviceCode: controller
    )
}

/// `seedGrowableWorld`'s meshed hub — no tendMesh carrier, no salvage, since
/// this suite is not about growth — plus a staged, tagged survey fleet.
private func seedSurveyEnsureReadyWorld(_ db: Database) throws {
    try seedGrowableWorld(db, carriers: [], salvage: [:])
    try seedSurveyEnsureFleet(db)
}

private let secondTheatreSystem = "VEGA"
private let secondTheatreHubLocation = "VEGA-3"
private let secondTheatreCarrier = "SV2"

/// A second, independently meshed hub far enough from `SOL` to form its own
/// mesh component — `seedGrowableWorld`'s shape, reproduced at `VEGA` rather
/// than shared with it, so it derives its own operational theatre.
private func seedSecondTheatre(_ db: Database) throws {
    try seedRelay(db, code: "REL2", location: secondTheatreSystem)
    try seedStar(db, designation: secondTheatreSystem, x: 300, y: 300, z: 300)
    try seedPrintHub(db, code: "HUB2", location: secondTheatreHubLocation)
    try seedHubStockpile(db, location: secondTheatreHubLocation, resources: BrainCeiling.aggregateSpendFloor * 2)
}

private func surveyEnsureDirectives(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in try Directive.all.fetchAll(db) }
}

private func surveyEnsureTick(_ database: any DatabaseWriter) async {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(surveyEnsureNow)
        $0.uuid = .incrementing
    } operation: {
        _ = await Brain(now: surveyEnsureNow).evaluateOnce()
    }
}

@Suite("Brain — ensureSurvey")
struct BrainEnsureSurveyTests {
    /// The headline: a ready, staged fleet with no live survey launches
    /// exactly one row, shaped as the design specifies.
    @Test func readyFleetWithNoLiveSurveyInsertsExactlyOneRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSurveyEnsureReadyWorld(db) }

        await surveyEnsureTick(database)

        let directives = try await surveyEnsureDirectives(database)
        let survey = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(survey.kind == .surveyRun)
        #expect(survey.deviceCode == surveyEnsureCarrier)
        #expect(survey.roamCentre == surveyEnsureHubSystem)
        #expect(survey.step == SurveyRun().firstStep)
        #expect(survey.status == .running)
    }

    /// The loop's headline change: an idle theatre must `continue`, not
    /// `return`, or it silently suppresses every theatre after it. SOL has
    /// no survey fleet at all; VEGA is fully staged and must still launch.
    @Test func anIdleTheatreDoesNotSuppressAReadyOnesLaunch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSecondTheatre(db)
            try seedSurveyEnsureFleet(
                db, carrier: secondTheatreCarrier, controller: "AMI2", drone: "DRONE2",
                location: secondTheatreHubLocation
            )
        }

        await surveyEnsureTick(database)

        let directives = try await surveyEnsureDirectives(database)
        let survey = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(survey.kind == .surveyRun)
        #expect(survey.deviceCode == secondTheatreCarrier)
        #expect(survey.roamCentre == secondTheatreSystem)
        #expect(survey.theatreDepot == secondTheatreHubLocation)
    }

    /// A second tick against the row the first tick just launched inserts
    /// nothing — the live row already owns the fleet.
    @Test func aSecondTickWithTheLaunchedRowStillLiveInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSurveyEnsureReadyWorld(db) }
        await surveyEnsureTick(database)
        let afterFirst = try await surveyEnsureDirectives(database)
        #expect(afterFirst.count == 1)

        await surveyEnsureTick(database)

        let afterSecond = try await surveyEnsureDirectives(database)
        #expect(afterSecond == afterFirst, "the row the first tick launched already owns the fleet")
    }

    /// Every owning status — `.running`, `.needsAttention`, `.paused` — holds
    /// the fleet. A halted run is one Retry from moving and a paused run is
    /// the operator's own choice; neither should be relaunched around.
    @Test(arguments: [DirectiveStatus.running, .needsAttention, .paused])
    func aLiveSurveyInAnyOwningStatusBlocksRelaunch(_ status: DirectiveStatus) async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSurveyEnsureReadyWorld(db)
            try seedDirective(db, id: "EXISTING", kind: .surveyRun, status: status, deviceCode: surveyEnsureCarrier)
        }
        let before = try await surveyEnsureDirectives(database)

        await surveyEnsureTick(database)

        let after = try await surveyEnsureDirectives(database)
        #expect(after == before, "a \(status) survey already owns the fleet — nothing else should launch")
    }

    /// `.completed`/`.cancelled` do NOT count as live, so a finished roam
    /// (a roam is unbounded and should not finish, but if one does) is
    /// replaced — the old row is left exactly as it was.
    @Test(arguments: [DirectiveStatus.completed, .cancelled])
    func aFinishedSurveyDoesNotBlockAFreshRoam(_ status: DirectiveStatus) async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSurveyEnsureReadyWorld(db)
            try seedDirective(db, id: "FINISHED", kind: .surveyRun, status: status, deviceCode: surveyEnsureCarrier)
        }
        let finishedBefore = try #require(
            try await database.read { db in try Directive.where { $0.id.eq("FINISHED") }.fetchOne(db) }
        )

        await surveyEnsureTick(database)

        let after = try await surveyEnsureDirectives(database)
        #expect(after.count == 2, "the finished row does not hold the fleet, so a fresh roam launches")
        let finishedAfter = try #require(after.first { $0.id == "FINISHED" })
        #expect(finishedAfter == finishedBefore, "the finished row is left exactly as it was")
        let launched = try #require(after.first { $0.id != "FINISHED" })
        #expect(launched.kind == .surveyRun)
        #expect(launched.status == .running)
    }

    /// An idle verdict — no tagged, staged fleet — writes nothing at all,
    /// directives or otherwise.
    @Test func anIdleVerdictInsertsNothingAndWritesNothingAtAll() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowableWorld(db, carriers: [], salvage: [:]) }
        let devicesBefore = try await database.read { db in try Device.all.fetchAll(db) }

        await surveyEnsureTick(database)

        let directives = try await surveyEnsureDirectives(database)
        #expect(directives.isEmpty)
        let devicesAfter = try await database.read { db in try Device.all.fetchAll(db) }
        #expect(devicesAfter == devicesBefore, "an idle survey verdict must not mutate any device row")
    }

    /// The additive-writes witness, `allWritesAreAdditive`'s shape: a launch
    /// must not touch a pre-existing row of a DIFFERENT kind — asserted over
    /// the whole directive table, not a count of survey rows.
    @Test func theBrainWritesNoOtherRowWhileLaunchingASurvey() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSurveyEnsureReadyWorld(db)
            try seedDirective(db, id: "OTHER", kind: .salvageRun, deviceCode: "UNRELATED")
        }
        let otherBefore = try #require(
            try await database.read { db in try Directive.where { $0.id.eq("OTHER") }.fetchOne(db) }
        )

        await surveyEnsureTick(database)

        let after = try await surveyEnsureDirectives(database)
        #expect(after.count == 2, "exactly the pre-existing row plus the one survey launch")
        let otherAfter = try #require(after.first { $0.id == "OTHER" })
        #expect(otherAfter == otherBefore, "the brain must touch nothing but the row it inserts")
    }

    /// The headline, end to end: two theatres, each with its own ready fleet,
    /// both launch in the SAME tick, each stamped with its own theatre's tag.
    @Test func twoReadyTheatresBothLaunchInOneTick() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSurveyEnsureReadyWorld(db)
            try seedSecondTheatre(db)
            try seedSurveyEnsureFleet(
                db, carrier: secondTheatreCarrier, controller: "AMI2", drone: "DRONE2",
                location: secondTheatreHubLocation
            )
        }

        await surveyEnsureTick(database)

        let rows = try await surveyEnsureDirectives(database).filter { $0.kind == .surveyRun }
        #expect(rows.count == 2, "both theatres must launch in the same tick")
        let first = try #require(rows.first { $0.deviceCode == surveyEnsureCarrier })
        let second = try #require(rows.first { $0.deviceCode == secondTheatreCarrier })
        #expect(first.fleetTag == SurveyRun.fleetTag(forTheatre: growHubLocation))
        #expect(second.fleetTag == SurveyRun.fleetTag(forTheatre: secondTheatreHubLocation))
    }

    /// Candidate SCOPING only — SOL's per-theatre tag can never literally
    /// match VEGA's carrier's bare one, so this proves nothing about
    /// `reservedDevices` itself; see the legacy-collision test below for that.
    @Test func aLiveTheatresOwnTagDoesNotDisturbAnotherTheatresLaunch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSurveyEnsureReadyWorld(db)
            try seedDirective(
                db, id: "LIVE-SOL", kind: .surveyRun, status: .running,
                deviceCode: surveyEnsureCarrier, fleetTag: SurveyRun.fleetTag(forTheatre: growHubLocation),
                theatreDepot: growHubLocation
            )
            try seedSecondTheatre(db)
            try seedSurveyEnsureFleet(
                db, carrier: secondTheatreCarrier, controller: "AMI2", drone: "DRONE2",
                location: secondTheatreHubLocation
            )
        }

        await surveyEnsureTick(database)

        let rows = try await surveyEnsureDirectives(database).filter { $0.kind == .surveyRun }
        #expect(rows.count == 2, "VEGA's fleet must still launch")
        #expect(rows.contains { $0.deviceCode == secondTheatreCarrier })
    }

    /// The accepted residual (report Concern #2), for survey too: an
    /// already-running directive still carrying the literal bare tag still
    /// reserves a different theatre's still-bare carrier.
    @Test func legacyBareTaggedLiveRunStillCollidesWithAnotherTheatresBareCarrier() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSurveyEnsureReadyWorld(db)
            try seedDirective(
                db, id: "LIVE-SOL", kind: .surveyRun, status: .running,
                deviceCode: surveyEnsureCarrier, fleetTag: SurveyRun.defaultFleetTag,
                theatreDepot: growHubLocation
            )
            try seedSecondTheatre(db)
            try seedSurveyEnsureFleet(
                db, carrier: secondTheatreCarrier, controller: "AMI2", drone: "DRONE2",
                location: secondTheatreHubLocation
            )
        }

        await surveyEnsureTick(database)

        let rows = try await surveyEnsureDirectives(database).filter { $0.kind == .surveyRun }
        #expect(rows.count == 1, "VEGA's carrier is swept by SOL's literal bare-tag reservation")
        #expect(rows.first?.id == "LIVE-SOL")
    }
}

// MARK: - `BrainReport.survey`

private func surveyEnsureReport(_ database: any DatabaseWriter) async -> BrainReport {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(surveyEnsureNow)
        $0.uuid = .incrementing
    } operation: {
        await Brain(now: surveyEnsureNow).report()
    }
}

@Suite("Brain — the survey verdict on the published report")
struct BrainSurveyReportTests {
    /// The tick that launches reports `.ready` — the snapshot it decided from
    /// had no live row yet — while the launch it triggers lands in the SAME
    /// tick. The report states what was READ, not the write beside it.
    @Test func theLaunchingTickReportsReadyAndStillLaunches() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSurveyEnsureReadyWorld(db) }

        let report = await surveyEnsureReport(database)

        #expect(report.survey == .ready(carrier: surveyEnsureCarrier, roamCentre: surveyEnsureHubSystem))
        let directives = try await surveyEnsureDirectives(database)
        #expect(directives.count == 1, "the launch this same tick's `ensureSurvey` performs")
        #expect(directives.first?.kind == .surveyRun)
    }

    /// The next tick's fresh read finds the row `.ready` launched, and the
    /// report flips to `.launched` — a live run, not a repeated verdict.
    @Test func theFollowingTickReportsLaunchedOffTheLiveRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSurveyEnsureReadyWorld(db) }
        _ = await surveyEnsureReport(database)

        let report = await surveyEnsureReport(database)

        #expect(
            report.survey
                == .launched(carrier: surveyEnsureCarrier, roamCentre: surveyEnsureHubSystem, status: .running)
        )
    }

    /// End to end through the real engine: `.needsAttention`/`.paused` both
    /// keep `ensureSurvey`'s relaunch guard closed, and the published report
    /// must carry that same status through rather than default to running.
    @Test(arguments: [DirectiveStatus.needsAttention, .paused])
    func aHaltedOrPausedLiveSurveyReportsItsOwnStatus(_ status: DirectiveStatus) async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSurveyEnsureReadyWorld(db)
            try seedDirective(db, id: "EXISTING", kind: .surveyRun, status: status, deviceCode: surveyEnsureCarrier)
        }

        let report = await surveyEnsureReport(database)

        let expected: BrainSurveyStatus.LaunchedStatus = status == .needsAttention ? .needsAttention : .paused
        #expect(report.survey == .launched(carrier: surveyEnsureCarrier, roamCentre: nil, status: expected))
    }

    /// No fleet at all: the published report idles with the exact reason
    /// `surveyReadiness` names, so an operator reading the card sees what the
    /// log would say too.
    @Test func anUnstagedWorldReportsIdleWithTheNamedReason() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowableWorld(db, carriers: [], salvage: [:]) }

        let report = await surveyEnsureReport(database)

        #expect(report.survey == .idle(reason: "no vessel is tagged \(Brain.surveyCarrierTag)"))
    }
}
