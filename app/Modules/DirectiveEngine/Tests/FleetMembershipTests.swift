//
//  FleetMembershipTests.swift
//  Replicould — DirectiveEngine
//
//  The one membership rule, for every goal that fields a fleet.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

/// `X` stands 1 ly from `DEPOT-A`'s system and 20 from `DEPOT-B`'s, so
/// location alone always answers A — only a tag can move a device to B.
private let membershipResolver = TheatreResolver(
    theatres: [
        Theatre(depot: "DEPOT-A", system: "A", origin: .derived, readiness: .operational, stock: 0),
        Theatre(depot: "DEPOT-B", system: "B", origin: .pinned, readiness: .operational, stock: 0),
    ],
    starPositions: [
        "A": Position(x: 0, y: 0, z: 0),
        "X": Position(x: 1, y: 0, z: 0),
        "B": Position(x: 21, y: 0, z: 0),
    ],
    components: ["A": "MESH", "X": "MESH", "B": "MESH"]
)

private func member(_ tags: [String], at location: String? = "X-1") -> Device {
    deviceFixture(code: "D1", type: "ami_transport_controller", location: location, tags: tags)
}

private func isMember(_ device: Device, of depot: String, goal: FleetTag.Goal) -> Bool {
    FleetMembership.belongs(device, toDepot: depot, goal: goal, resolver: membershipResolver)
}

private let fleetGoals: [FleetTag.Goal] = [.haul, .survey, .salvage]

@Suite("Fleet membership — a scoped tag outranks location")
struct FleetMembershipTests {
    @Test("a device tagged for the far theatre is the far theatre's", arguments: fleetGoals)
    func aScopedTagOutranksLocation(goal: FleetTag.Goal) {
        let device = member(["auto:\(goal.rawValue):DEPOT-B"])
        #expect(isMember(device, of: "DEPOT-B", goal: goal))
        #expect(!isMember(device, of: "DEPOT-A", goal: goal))
    }

    @Test("a device wearing only the bare tag is placed by location", arguments: fleetGoals)
    func anUnscopedDeviceIsPlacedByLocation(goal: FleetTag.Goal) {
        let device = member(["auto:\(goal.rawValue)"])
        #expect(isMember(device, of: "DEPOT-A", goal: goal))
        #expect(!isMember(device, of: "DEPOT-B", goal: goal))
    }

    @Test("wearing both tags, the scoped one decides", arguments: fleetGoals)
    func theScopedTagWinsOverTheBareOne(goal: FleetTag.Goal) {
        let device = member(["auto:\(goal.rawValue)", "auto:\(goal.rawValue):DEPOT-B"])
        #expect(isMember(device, of: "DEPOT-B", goal: goal))
        #expect(!isMember(device, of: "DEPOT-A", goal: goal))
    }

    /// Untagging is the operator's opt-out, so standing in a theatre's own
    /// system must never enrol a device on its own.
    @Test("an untagged device belongs to no theatre", arguments: fleetGoals)
    func anUntaggedDeviceBelongsNowhere(goal: FleetTag.Goal) {
        #expect(!isMember(member([]), of: "DEPOT-A", goal: goal))
        #expect(!isMember(member(["auto:carrier"]), of: "DEPOT-A", goal: goal))
    }

    /// A stowed or mid-cruise device has no location to be placed by, so the
    /// tag is the only handle on it.
    @Test("a scoped tag places a device the census cannot", arguments: fleetGoals)
    func aScopedTagPlacesALocationlessDevice(goal: FleetTag.Goal) {
        let tagged = member(["auto:\(goal.rawValue):DEPOT-B"], at: nil)
        #expect(isMember(tagged, of: "DEPOT-B", goal: goal))
        #expect(!isMember(tagged, of: "DEPOT-A", goal: goal))
        #expect(!isMember(member(["auto:\(goal.rawValue)"], at: nil), of: "DEPOT-A", goal: goal))
    }

    /// The two entry points are one rule: a caller holding the theatre and one
    /// holding only a row's depot stamp must get the same answer.
    @Test("the theatre-taking and depot-taking forms agree")
    func bothEntryPointsAgree() {
        let device = member(["auto:haul:DEPOT-B"])
        let theatre = membershipResolver.theatres[1]
        #expect(
            FleetMembership.belongs(device, to: theatre, goal: .haul, resolver: membershipResolver)
                == isMember(device, of: theatre.depot, goal: .haul)
        )
        #expect(FleetMembership.belongs(device, to: theatre, goal: .haul, resolver: membershipResolver))
    }
}
