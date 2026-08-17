//
//  BrainCarrierTagTests.swift
//  Replicould — DirectiveEngine
//
//  Which vessels the brain may spend. The type check alone made every idle
//  HEAVEN vessel standing at the print hub fair game, and on 2026-08-04 that
//  meant three vessels at `AINALRAM-BELT-1` became three Relay Runs competing
//  for one shared print queue. Opting a fleet into automation is an operator's
//  decision and no column records it, so it rides a tag — the same mechanism
//  the Haul Run already uses to name a working set (`auto:haul`).
//
//  The load-bearing half is the ABSENCE case: untagged must mean "launch
//  nothing and say why", never "fall back to any hull".
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

private let hubLocation = "AINALRAM-BELT-1"

private func vessel(
    _ code: String,
    type: String = "heaven_vessel",
    tags: [String] = [],
    location: String? = hubLocation,
    status: String = "idle",
    features: [String] = carrierHullFeatures,
    availableCommands: [String] = []
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
        features: features, tags: tags, detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 10_000), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func fleet(_ devices: [Device]) -> [String: Device] {
    Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last })
}

@Suite("Brain — the carrier tag gates every launch")
struct BrainCarrierTagTests {
    @Test("an untagged vessel is not a free carrier")
    func untaggedVesselIsNotFree() {
        let devices = fleet([vessel("V1")])

        #expect(Brain.freeCarrier(at: hubLocation, devices: devices, reserved: []) == nil)
    }

    @Test("a tagged vessel is")
    func taggedVesselIsFree() {
        let devices = fleet([vessel("V1", tags: [Brain.carrierTag.string])])

        #expect(Brain.freeCarrier(at: hubLocation, devices: devices, reserved: [])?.deviceCode == "V1")
    }

    /// **The live regression.** The server normalises tags to lowercase, so a
    /// vessel the operator tagged `auto:tendMesh` from the device inspector
    /// comes back wearing `auto:tendmesh`. An exact-match gate refused exactly
    /// the vessel that had just been opted in — the one failure mode this whole
    /// gate must not have. Both spellings resolve, in both directions.
    @Test("the tag resolves whatever case the fleet reports it in", arguments: [
        "auto:tendmesh", "auto:tendMesh", "AUTO:TENDMESH",
    ])
    func theTagResolvesInAnyCase(_ stored: String) {
        let devices = fleet([vessel("965AC2C3", tags: [stored])])

        #expect(
            Brain.freeCarrier(at: hubLocation, devices: devices, reserved: [])?.deviceCode == "965AC2C3",
            "a vessel tagged \(stored) must be flyable"
        )
    }

    /// The live fleet's exact shape: three idle vessels, none tagged. Before the
    /// gate this launched three runs.
    @Test("a hub full of untagged vessels yields no carrier at all")
    func untaggedFleetYieldsNothing() {
        let devices = fleet([vessel("965AC2C3"), vessel("C7836770"), vessel("F2908E6E")])

        #expect(Brain.freeCarrier(at: hubLocation, devices: devices, reserved: []) == nil)
    }

    /// Tagging is not a bypass of the other three clauses — a tagged vessel that
    /// is busy, reserved, or somewhere else stays unavailable.
    @Test("the tag does not override the other freedom clauses", arguments: [
        ("busy", "travelling", hubLocation, false),
        ("elsewhere", "idle", "SOMEWHERE-ELSE", false),
        ("reserved", "idle", hubLocation, true),
    ])
    func tagDoesNotOverrideOtherClauses(_ label: String, status: String, location: String, reserved: Bool) {
        let devices = fleet([vessel("V1", tags: [Brain.carrierTag.string], location: location, status: status)])

        let carrier = Brain.freeCarrier(
            at: hubLocation, devices: devices, reserved: reserved ? ["V1"] : []
        )

        #expect(carrier == nil, "a \(label) vessel must stay unavailable even when tagged")
    }

    /// Silence is the failure mode this guards: "no free carrier" reads as
    /// "they're all busy", which would send an operator hunting for a problem
    /// that does not exist instead of tagging a vessel.
    @Test("the blocker names the untagged state and the tag to apply")
    func blockerNamesTheUntaggedState() {
        let devices = fleet([vessel("965AC2C3"), vessel("C7836770")])

        let blocker = Brain.carrierBlocker(
            at: hubLocation, devices: devices, reserved: [], directives: []
        )

        #expect(blocker.contains(Brain.carrierTag.string))
        #expect(blocker.contains("965AC2C3"))
        #expect(!blocker.contains("no free carrier"), "the untagged case must not be reported as busyness")
    }

    /// With nothing of the carrier type there at all there is no tagging advice
    /// to give — the bare sentence stays.
    @Test("an empty hub keeps the bare no-carrier sentence")
    func emptyHubKeepsBareSentence() {
        let blocker = Brain.carrierBlocker(
            at: hubLocation, devices: [:], reserved: [], directives: []
        )

        #expect(blocker == "no free carrier at \(hubLocation)")
    }
}

@Suite("Brain — the carrier gate is capability, not type")
struct BrainCarrierHullGateTests {
    /// The live fleet's shape: the operator's tendMesh carrier is a
    /// `racing_vessel` with the identical feature set. The type string must
    /// not matter — cradle + surge is what makes it a carrier.
    @Test("an idle tagged racing vessel at the hub is a free carrier")
    func racingVesselIsAFreeCarrier() {
        let devices = fleet([vessel("R1", type: "racing_vessel", tags: [Brain.carrierTag.string])])

        #expect(
            Brain.freeCarrier(at: hubLocation, devices: devices, reserved: [])?.deviceCode == "R1"
        )
        #expect(Brain.isFreeCarrier(devices["R1"]!, at: hubLocation, reserved: []))
    }

    /// A tagged racing vessel that is merely busy is a CANDIDATE the blocker
    /// explains per-vessel — never folded into "untagged".
    @Test("a busy tagged racing vessel gets a per-vessel clause, not untagged")
    func busyRacingVesselGetsAPerVesselClause() {
        let devices = fleet([
            vessel("R1", type: "racing_vessel", tags: [Brain.carrierTag.string], status: "travelling")
        ])

        let blocker = Brain.carrierBlocker(
            at: hubLocation, devices: devices, reserved: [], directives: []
        )

        #expect(blocker.contains("R1 is travelling"))
        #expect(!blocker.contains("untagged"))
    }

    /// A tag on a hull that cannot carry the fleet is a misapplied opt-in —
    /// the remedy is moving the tag, so the device is named as such.
    @Test("a tagged non-carrier is named as tagged but not a carrier hull")
    func taggedNonCarrierIsNamedMistagged() {
        let devices = fleet([
            vessel(
                "P1", type: "propulsor", tags: [Brain.carrierTag.string],
                features: ["cruise", "stow", "diversion"]
            )
        ])

        let blocker = Brain.carrierBlocker(
            at: hubLocation, devices: devices, reserved: [], directives: []
        )

        #expect(blocker.contains("P1"))
        #expect(blocker.contains("not a carrier hull"))
        #expect(!blocker.contains("untagged"))
    }

    /// Moving the tag is a location-independent remedy, so a mistagged device
    /// is named wherever it stands — stowed (nil location) included.
    @Test("a stowed tagged non-carrier is still named")
    func stowedTaggedNonCarrierIsStillNamed() {
        let devices = fleet([
            vessel(
                "P1", type: "propulsor", tags: [Brain.carrierTag.string], location: nil,
                features: ["cruise", "stow", "diversion"]
            )
        ])

        let blocker = Brain.carrierBlocker(
            at: hubLocation, devices: devices, reserved: [], directives: []
        )

        #expect(blocker.contains("P1"))
        #expect(blocker.contains("not a carrier hull"))
    }
}

@Suite("Brain — the restock host must never be a carrier hull")
struct BrainRestockHostGateTests {
    private func view(_ devices: [Device]) -> WorldView {
        WorldView(
            devices: fleet(devices), starPositions: [:], meshSystems: [],
            salvageUnits: [:], eventSystems: [],
            theatres: singleOperationalTheatre(depot: hubLocation).theatres,
            now: Date(timeIntervalSince1970: 10_000)
        )
    }

    /// `A1` sorts before `B1`, so only the carrier-hull exclusion — not code
    /// order — can hand the restock to the autofactory.
    @Test("a print-capable racing vessel yields the restock to the autofactory")
    func printCapableRacingVesselYieldsToTheAutofactory() {
        let racing = vessel(
            "A1", type: "racing_vessel", availableCommands: ["enqueue_print"]
        )
        let factory = vessel(
            "B1", type: "autofactory", features: [], availableCommands: ["enqueue_print"]
        )

        let world = view([racing, factory])
        #expect(Brain.restockHost(in: world, theatre: world.theatres[0])?.deviceCode == "B1")
    }

    @Test("a lone print-capable racing vessel hosts no restock at all")
    func loneRacingVesselHostsNothing() {
        let racing = vessel(
            "A1", type: "racing_vessel", availableCommands: ["enqueue_print"]
        )

        let world = view([racing])
        #expect(Brain.restockHost(in: world, theatre: world.theatres[0]) == nil)
    }
}
