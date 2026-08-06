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
        updatedAt: surveyFixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func surveyReadinessView(
    devices: [Device],
    hubLocation: String? = nil,
    starPositions: [String: Position] = [:]
) -> WorldView {
    WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: starPositions,
        meshSystems: [],
        salvageUnits: [:],
        eventSystems: [],
        hubLocation: hubLocation,
        now: surveyFixtureNow
    )
}

/// A fully staged survey vessel: tagged, a controller stowed aboard offering
/// `survey_system`, and one drone the controller has adopted, also aboard.
private func surveyReadinessStagedFleet() -> [Device] {
    [
        surveyReadinessDevice("V1", type: Brain.carrierDeviceType, tags: [Brain.surveyCarrierTag]),
        surveyReadinessDevice(
            "AMI1", type: "ami_survey_controller", stowedIn: "V1", directives: ["survey_system"]
        ),
        surveyReadinessDevice("DRONE1", type: "survey_drone", stowedIn: "V1", controllerDeviceCode: "AMI1"),
    ]
}

@Suite("Brain — the survey readiness verdict")
struct BrainSurveyTests {
    @Test("a tagged, staged fleet with a census-known anchor system is ready to launch")
    func readyToLaunch() {
        let view = surveyReadinessView(
            devices: surveyReadinessStagedFleet(),
            hubLocation: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        #expect(Brain.surveyReadiness(view: view) == .launch(carrier: "V1", roamCentre: "AINALRAM"))
    }

    @Test("no vessel tagged auto:survey idles, naming the tag")
    func untaggedFleetIdles() {
        let devices = [surveyReadinessDevice("V1", type: Brain.carrierDeviceType)]
        let view = surveyReadinessView(
            devices: devices, hubLocation: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason.contains(Brain.surveyCarrierTag))
        #expect(reason.contains("V1"))
    }

    @Test("a tagged vessel with no survey controller aboard idles, never stalls")
    func noControllerAboardIdles() {
        let devices = [surveyReadinessDevice("V1", type: Brain.carrierDeviceType, tags: [Brain.surveyCarrierTag])]
        let view = surveyReadinessView(
            devices: devices, hubLocation: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view) else {
            Issue.record("expected idle, never a stall")
            return
        }
        #expect(reason.contains("V1"))
        #expect(reason.contains("controller"))
    }

    @Test("a tagged vessel whose controller has adopted no drone aboard idles, naming that")
    func noAdoptedDroneAboardIdles() {
        let devices = [
            surveyReadinessDevice("V1", type: Brain.carrierDeviceType, tags: [Brain.surveyCarrierTag]),
            surveyReadinessDevice(
                "AMI1", type: "ami_survey_controller", stowedIn: "V1", directives: ["survey_system"]
            ),
        ]
        let view = surveyReadinessView(
            devices: devices, hubLocation: "AINALRAM-BELT-1",
            starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0)]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason.contains("V1"))
        #expect(reason.contains("AMI1"))
        #expect(reason.contains("drone"))
    }

    @Test("a roam centre the census does not know idles, naming it")
    func unknownRoamCentreIdles() {
        let view = surveyReadinessView(
            devices: surveyReadinessStagedFleet(),
            hubLocation: "AINALRAM-BELT-1",
            starPositions: [:]
        )

        guard case let .idle(reason) = Brain.surveyReadiness(view: view) else {
            Issue.record("expected idle — SurveyRun.plan would exhaust immediately")
            return
        }
        #expect(reason.contains("AINALRAM"))
    }

    @Test("an anchor with no resolvable location idles rather than crashing")
    func unresolvedAnchorIdles() {
        let view = surveyReadinessView(
            devices: surveyReadinessStagedFleet(),
            hubLocation: nil,
            starPositions: [:]
        )

        guard case .idle = Brain.surveyReadiness(view: view) else {
            Issue.record("expected idle")
            return
        }
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
        let view = surveyReadinessView(devices: [], hubLocation: nil)

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
        let view = surveyReadinessView(devices: [], hubLocation: nil)

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
            hubLocation: "AINALRAM-BELT-1",
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
        let devices = [surveyReadinessDevice("V1", type: Brain.carrierDeviceType)]
        let view = surveyReadinessView(devices: devices, hubLocation: nil)

        guard case let .idle(status) = Brain.surveyStatus(directives: [], view: view),
              case let .idle(readiness) = Brain.surveyReadiness(view: view)
        else {
            Issue.record("expected both to idle")
            return
        }
        #expect(status == readiness)
    }
}

// MARK: - `Brain.ensureSurvey`

private let surveyEnsureNow = Date(timeIntervalSince1970: 20_000)
private let surveyEnsureHubSystem = "SOL"
private let surveyEnsureCarrier = "SV1"

/// The DB-backed twin of `surveyReadinessDevice` above — same shape, written
/// straight to the database rather than held as a value.
private func seedSurveyEnsureDevice(
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
            updatedAt: surveyEnsureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

/// A fully staged, tagged survey fleet: `seedSurveyEnsureDevice`'s three rows,
/// carrier + stowed controller + adopted drone.
private func seedSurveyEnsureFleet(_ db: Database, carrier: String = surveyEnsureCarrier) throws {
    try seedSurveyEnsureDevice(db, code: carrier, type: Brain.carrierDeviceType, tags: [Brain.surveyCarrierTag])
    try seedSurveyEnsureDevice(
        db, code: "AMI1", type: "ami_survey_controller", stowedIn: carrier, directives: ["survey_system"]
    )
    try seedSurveyEnsureDevice(
        db, code: "DRONE1", type: "survey_drone", stowedIn: carrier, controllerDeviceCode: "AMI1"
    )
}

/// `seedGrowableWorld`'s meshed hub — no tendMesh carrier, no salvage, since
/// this suite is not about growth — plus a staged, tagged survey fleet.
private func seedSurveyEnsureReadyWorld(_ db: Database) throws {
    try seedGrowableWorld(db, carriers: [], salvage: [:])
    try seedSurveyEnsureFleet(db)
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
