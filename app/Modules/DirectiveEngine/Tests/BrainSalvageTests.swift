//
//  BrainSalvageTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.salvageReadiness` as a pure function table: every gate names why it
//  declined, an unstaged fleet idles rather than manufacturing a stall, and
//  unmeshed salvage is not this goal's to reach.
//

import Foundation
import GameModels
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
