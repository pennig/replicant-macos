//
//  BrainSurveyTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.surveyReadiness` as a pure function table: every gate names the
//  reason it declined rather than a bare "not ready", and an unstaged vessel
//  must idle — never reach the mission and manufacture a stall.
//

import Foundation
import GameModels
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
