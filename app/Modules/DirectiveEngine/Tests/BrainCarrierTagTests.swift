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
    tags: [String] = [],
    location: String? = hubLocation,
    status: String = "idle"
) -> Device {
    Device(
        deviceCode: code, deviceType: Brain.carrierDeviceType, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: tags, detail: .object([:]),
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
        let devices = fleet([vessel("V1", tags: [Brain.carrierTag])])

        #expect(Brain.freeCarrier(at: hubLocation, devices: devices, reserved: [])?.deviceCode == "V1")
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
        let devices = fleet([vessel("V1", tags: [Brain.carrierTag], location: location, status: status)])

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

        #expect(blocker.contains(Brain.carrierTag))
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
