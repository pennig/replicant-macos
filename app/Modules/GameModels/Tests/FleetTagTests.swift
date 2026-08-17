//
//  FleetTagTests.swift
//  GameModelsTests
//
//  The `auto:<goal>[:<scope>]` grammar FleetTag replaces: parsing, the
//  canonical string form, and the two device-side match policies.
//

import Foundation
import Testing
@testable import GameModels

private func device(tags: [String]) -> Device {
    Device(
        deviceCode: "V1", deviceType: "heaven_vessel", replicantCode: "R1",
        status: "idle", location: "SOL-3", locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: [], tags: tags,
        detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("FleetTag")
struct FleetTagTests {
    @Test func parsesUnscopedAndScoped() {
        #expect(FleetTag(parsing: "auto:haul") == FleetTag(goal: .haul))
        #expect(FleetTag(parsing: "auto:haul:AINALRAM-BELT-1") == FleetTag(goal: .haul, scope: .theatre(depot: "ainalram-belt-1")))
        #expect(FleetTag(parsing: "auto:mine:TAU-BELT-2") == FleetTag(goal: .mine, scope: .belt(designation: "tau-belt-2")))
        #expect(FleetTag(parsing: "AUTO:TendMesh") == FleetTag(goal: .tendMesh))
        #expect(FleetTag(parsing: "auto:unknown") == nil)
        #expect(FleetTag(parsing: "manual:haul") == nil)
    }

    @Test func stringIsCanonicalLowercase() {
        #expect(FleetTag(goal: .survey, scope: .theatre(depot: "SOL-1")).string == "auto:survey:sol-1")
    }

    @Test func carriesPolicies() {
        let d = device(tags: ["auto:survey"])
        let scoped = FleetTag(goal: .survey, scope: .theatre(depot: "SOL-1"))
        #expect(!d.carries(scoped, policy: .exact))
        #expect(d.carries(scoped, policy: .exactOrUnscoped))
        #expect(device(tags: ["auto:survey:sol-1"]).carries(scoped, policy: .exact))
    }

    @Test func scopedTagForGoal() {
        let tagged = device(tags: ["auto:survey", "auto:survey:sol-1"])
        #expect(tagged.scopedTag(for: .survey) == FleetTag(goal: .survey, scope: .theatre(depot: "sol-1")))
        #expect(device(tags: ["auto:survey"]).scopedTag(for: .survey) == nil)
    }

    @Test func roundTripsThroughDeviceTags() {
        let tag = FleetTag(goal: .mine, scope: .belt(designation: "TAU-BELT-2"))
        #expect(Device.normalizedTag(tag.string) == tag.string)
    }

    // R2 — see task-09-report.md for why scope-case-blind equality is required.
    @Test func scopeCaseDoesNotAffectEquality() {
        #expect(FleetTag(goal: .mine, scope: .theatre(depot: "sol-1")) == FleetTag(goal: .mine, scope: .belt(designation: "sol-1")))
    }
}
