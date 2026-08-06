//
//  DeviceListContainmentTests.swift
//  Replicould — Devices feature tests
//
//  Carrier mode's tree: controller-first precedence, the real two-level shape,
//  unresolved hosts, cycles, and sort order.
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListContainmentTests {

    /// Flattens a forest to `code(depth)` strings for readable assertions.
    private func shape(_ nodes: [DeviceListLayout.Node], depth: Int = 0) -> [String] {
        nodes.flatMap { node in
            ["\(node.device.deviceCode)(\(depth))"] + shape(node.children, depth: depth + 1)
        }
    }

    /// In all 10 live stowed-and-controlled cases the AMI controller is stowed
    /// in the very carrier its drones are stowed in. Controller-first renders
    /// Vessel → Controller → drones; stowed-first would render seven siblings.
    @Test func controllerBeatsStowed() {
        let vessel = makeDevice("VESSEL", type: "heaven_vessel")
        let controller = makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL")
        let droneA = makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL")
        let droneB = makeDevice("DRONEB", stowedIn: "VESSEL", controlledBy: "CTRL")

        let forest = DeviceListLayout.forest(fleet: [droneB, vessel, droneA, controller])
        expectNoDifference(
            shape(forest),
            ["VESSEL(0)", "CTRL(1)", "DRONEA(2)", "DRONEB(2)"]
        )
    }

    @Test func attachedIsLowestPrecedence() {
        let plate = makeDevice("PLATE", type: "surge_plate")
        let beacon = makeDevice("BEACON", type: "ftl_beacon", attachedTo: "PLATE")
        let forest = DeviceListLayout.forest(fleet: [beacon, plate])
        expectNoDifference(shape(forest), ["PLATE(0)", "BEACON(1)"])
    }

    /// The non-winning relationship survives as the row's badge.
    @Test func nonWinningRelationBecomesTheBadge() {
        let drone = makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL")
        expectNoDifference(
            DeviceListLayout.badge(for: drone, parentCode: "CTRL"),
            .stowed(in: "VESSEL")
        )
    }

    /// A promoted (top-level) device still badges its declared relation, so an
    /// unresolved host stays visible on the row.
    @Test func promotedDeviceBadgesItsFirstRelation() {
        let orphan = makeDevice("ORPHAN", controlledBy: "GONE")
        expectNoDifference(
            DeviceListLayout.badge(for: orphan, parentCode: nil),
            .controlled(by: "GONE")
        )
    }

    @Test func unresolvedHostPromotesToTopLevel() {
        let orphan = makeDevice("ORPHAN", stowedIn: "NOTINFLEET")
        let other = makeDevice("OTHER")
        let forest = DeviceListLayout.forest(fleet: [orphan, other])
        expectNoDifference(shape(forest), ["ORPHAN(0)", "OTHER(0)"])
    }

    /// Decision: an unresolved host promotes to top level rather than falling
    /// through to the next declared relation. Without this test, a change that
    /// made `hostCode(of:)` try `stowedInDeviceCode` after an absent controller
    /// would pass the whole suite — every other unresolved-host case here uses
    /// a device with only a single declared relation.
    @Test func unresolvedHostDoesNotFallThroughToTheNextRelation() {
        let vessel = makeDevice("VESSEL", type: "heaven_vessel")
        let stray = makeDevice("STRAY", stowedIn: "VESSEL", controlledBy: "GONE")
        let forest = DeviceListLayout.forest(fleet: [stray, vessel])
        // "HEAVEN Vessel" < "Survey Drone" (STRAY's default type), so VESSEL sorts first.
        expectNoDifference(shape(forest), ["VESSEL(0)", "STRAY(0)"])
        // The unresolved (higher-precedence) relation is what stays visible as the badge.
        expectNoDifference(
            DeviceListLayout.badge(for: stray, parentCode: nil),
            .controlled(by: "GONE")
        )
    }

    @Test func selfHostPromotesToTopLevel() {
        let looped = makeDevice("SELF", stowedIn: "SELF")
        expectNoDifference(shape(DeviceListLayout.forest(fleet: [looped])), ["SELF(0)"])
    }

    /// A cycle terminates and places every member exactly once, at top level.
    @Test func cycleDissolvesToRoots() {
        let a = makeDevice("AAAA", stowedIn: "BBBB")
        let b = makeDevice("BBBB", stowedIn: "CCCC")
        let c = makeDevice("CCCC", stowedIn: "AAAA")
        let forest = DeviceListLayout.forest(fleet: [a, b, c])
        expectNoDifference(shape(forest), ["AAAA(0)", "BBBB(0)", "CCCC(0)"])
    }

    /// A device dangling off a cycle is not itself in the cycle and must still
    /// nest, and every device is placed exactly once.
    @Test func everyDeviceIsPlacedExactlyOnce() {
        let a = makeDevice("AAAA", stowedIn: "BBBB")
        let b = makeDevice("BBBB", stowedIn: "AAAA")
        let hanger = makeDevice("HANG", stowedIn: "AAAA")
        let loose = makeDevice("LOOS")
        let forest = DeviceListLayout.forest(fleet: [a, b, hanger, loose])
        let placed = shape(forest).map { String($0.prefix(while: { $0 != "(" })) }
        expectNoDifference(placed.sorted(), ["AAAA", "BBBB", "HANG", "LOOS"])
        expectNoDifference(Set(placed).count, placed.count)
    }

    /// Sort within a level: type display name, then device code.
    /// "ftl_relay" displays as "FTL Relay" and "survey_drone" as "Survey Drone",
    /// so the two relays lead, ordered by code.
    @Test func sortsByTypeDisplayNameThenCode() {
        let forest = DeviceListLayout.forest(fleet: [
            makeDevice("ZZZZ", type: "ftl_relay"),
            makeDevice("AAAA", type: "survey_drone"),
            makeDevice("BBBB", type: "ftl_relay"),
        ])
        expectNoDifference(shape(forest), ["BBBB(0)", "ZZZZ(0)", "AAAA(0)"])
    }
}
