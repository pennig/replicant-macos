//
//  MineRecipeTests.swift
//  Replicould — DirectiveEngine
//
//  `MineRecipe` as a pure function table: the recipe counts, and the fleet
//  queries the print run and the mine run share.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

private let mineFixtureNow = Date(timeIntervalSince1970: 1_750_000_000)

private func mineDevice(
    _ code: String, type: String, tags: [String] = [], location: String? = nil,
    status: String = "idle", stowedIn: String? = nil, attachedTo: String? = nil,
    controllerDeviceCode: String? = nil,
    directive: (name: String, status: String, config: [String: JSONValue])? = nil,
    directives: [String] = [], commands: [String] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty { detail["available_directives"] = .array(directives.map(JSONValue.string)) }
    if let directive {
        detail["ami_directive"] = .object([
            "name": .string(directive.name), "config": .object(directive.config),
        ])
        detail["ami_directive_status"] = .string(directive.status)
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: attachedTo, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: [], tags: tags, detail: .object(detail),
        updatedAt: mineFixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private let hub = "AINALRAM-BELT-1"

/// A complete unassigned mine fleet standing at the hub — one row per recipe slot.
private func printedFleet() -> [Device] {
    var out: [Device] = []
    var n = 0
    for (type, qty) in MineRecipe.all {
        for _ in 0..<qty {
            n += 1
            out.append(mineDevice("M\(String(format: "%02d", n))", type: type, tags: [MineRecipe.fleetTag.string], location: hub))
        }
    }
    return out
}

@Suite("MineRecipe — the recipe and the fleet queries")
struct MineRecipeTests {
    @Test("the recipe is eleven devices, nine of which ride the carrier")
    func recipeCounts() {
        #expect(MineRecipe.carried.reduce(0) { $0 + $1.quantity } == 9)
        #expect(MineRecipe.all.reduce(0) { $0 + $1.quantity } == 11)
    }

    @Test("a complete printed fleet has no shortfall")
    func completeFleet() {
        #expect(MineRecipe.shortfall(at: hub, in: printedFleet()).isEmpty)
    }

    @Test("a missing drone shows as that type's shortfall")
    func missingDrone() {
        let fleet = printedFleet().filter { $0.deviceCode != "M02" }  // a mining_drone
        #expect(MineRecipe.shortfall(at: hub, in: fleet) == ["mining_drone": 1])
    }

    @Test("an installed mine's ferry controller at the hub is not unassigned")
    func ferryControllerExcluded() {
        var fleet = printedFleet()
        let tc = fleet.firstIndex { $0.deviceType == "ami_transport_controller" }!
        fleet[tc] = mineDevice(
            fleet[tc].deviceCode, type: "ami_transport_controller",
            tags: [MineRecipe.fleetTag.string], location: hub, status: "coordinating",
            directive: (name: "ferry", status: "active", config: [:])
        )
        #expect(MineRecipe.shortfall(at: hub, in: fleet) == ["ami_transport_controller": 1])
    }

    @Test("a device away from the hub, stowed, attached, or adopted is not unassigned")
    func locationAndOwnershipGates() {
        let away = mineDevice("A1", type: "mining_drone", tags: [MineRecipe.fleetTag.string], location: "ELSEWHERE-1")
        let attached = mineDevice("A2", type: "mining_drone", tags: [MineRecipe.fleetTag.string], location: hub, attachedTo: "CARRIER")
        let adopted = mineDevice("A3", type: "mining_drone", tags: [MineRecipe.fleetTag.string], location: hub, controllerDeviceCode: "AMI")
        for d in [away, attached, adopted] {
            #expect(!MineRecipe.isUnassigned(d, hub: hub))
        }
    }

    @Test("installed belts are auto:mine mining controllers standing away from the hub")
    func installedBelts() {
        let installed = mineDevice(
            "MC1", type: "ami_mining_controller", tags: [MineRecipe.fleetTag.string],
            location: "AMEDIOHA-BELT-1", status: "coordinating",
            directive: (name: "gather_evenly", status: "active", config: [:])
        )
        let atHub = mineDevice("MC2", type: "ami_mining_controller", tags: [MineRecipe.fleetTag.string], location: hub)
        let belts = MineRecipe.installedBelts(in: [installed, atHub], hub: hub)
        #expect(belts == ["AMEDIOHA-BELT-1"])
    }

    @Test("the idle carrier is the lowest-coded tagged surge carrier at the hub")
    func idleCarrier() {
        let a = mineDevice("CB", type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag.string], location: hub)
        let b = mineDevice("CA", type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag.string], location: hub)
        let busy = mineDevice("AA", type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag.string], location: hub, status: "travelling")
        #expect(MineRecipe.idleCarrier(at: hub, in: [a, b, busy])?.deviceCode == "CA")
    }
}
