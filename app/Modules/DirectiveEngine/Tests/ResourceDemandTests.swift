//
//  ResourceDemandTests.swift
//  Replicould — DirectiveEngine
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

/// Builds an event whose `progress.options` carry the given requirement lines.
/// Mirrors the live `accounts/events` shape, so the decode under test is the
/// real one.
private func event(
    _ designation: String,
    status: String = "active",
    options: [(name: String, resources: [(String, Int, Int)], devices: [(String, Int, Int)])]
) -> LocationEvent {
    let optionValues: [JSONValue] = options.map { option in
        .object([
            "name": .string(option.name),
            "met": .bool(false),
            "resources": .array(option.resources.map { line in
                .object([
                    "resource_type": .string(line.0),
                    "current": .number(Double(line.1)),
                    "required": .number(Double(line.2)),
                    "met": .bool(line.1 >= line.2),
                ])
            }),
            "devices": .array(option.devices.map { line in
                .object([
                    "device_type": .string(line.0),
                    "current": .number(Double(line.1)),
                    "required": .number(Double(line.2)),
                    "met": .bool(line.1 >= line.2),
                ])
            }),
        ])
    }
    return LocationEvent(
        designation: designation,
        location: "CUHECHIA-4",
        status: status,
        detail: .object([
            "progress": .object(["met": .bool(false), "options": .array(optionValues)])
        ]),
        firstSeenAt: Date(timeIntervalSince1970: 1_750_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

private let defenceGrid = ResourceCost(
    silicates: 50, structural: 200, rares: 50, conductive: 100
)

@Suite("ResourceDemand — pricing open events")
struct ResourceDemandTests {
    @Test("a resource line contributes only its unmet remainder")
    func unmetRemainderOnly() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [("conductive", 40, 100)], [])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 60)
    }

    @Test("a met line contributes nothing and never goes negative")
    func metLineContributesNothing() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [("conductive", 150, 100)], [])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == nil)
    }

    @Test("a device requirement is priced through its blueprint bill")
    func devicesPricedThroughBills() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [], [("defence_grid", 0, 2)])])],
            bills: ["defence_grid": defenceGrid],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 200)
        #expect(demand.total["structural"] == 400)
        #expect(demand.total["rares"] == 100)
        #expect(demand.total["silicates"] == 100)
        #expect(demand.total["carbon"] == nil)
    }

    @Test("a partial device delivery is billed for only the remaining count")
    func partialDeviceDeliveryBillsRemainder() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [], [("defence_grid", 1, 3)])])],
            bills: ["defence_grid": defenceGrid],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 200)
        #expect(demand.total["structural"] == 400)
        #expect(demand.total["rares"] == 100)
        #expect(demand.total["silicates"] == 100)
    }

    @Test("demand for the same type accumulates across events")
    func crossEventAccumulation() {
        let demand = ResourceDemand.compute(
            events: [
                event("E-1", options: [("default", [("conductive", 0, 40)], [])]),
                event("E-2", options: [("default", [("conductive", 0, 25)], [])]),
            ],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 65)
    }

    @Test("only the cheapest priceable option of an event contributes")
    func cheapestOptionWins() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [
                ("expensive", [("conductive", 0, 500)], []),
                ("cheap", [("volatiles", 0, 10)], []),
            ])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["volatiles"] == 10)
        #expect(demand.total["conductive"] == nil)
    }

    @Test("a cost tie between options breaks by name, deterministically")
    func cheapestTieBreaksByName() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [
                ("beta", [("conductive", 0, 10)], []),
                ("alpha", [("volatiles", 0, 10)], []),
            ])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["volatiles"] == 10)
        #expect(demand.total["conductive"] == nil)
        #expect(demand.pricedEvents["E-1"]?.map(\.name) == ["alpha", "beta"])
    }

    @Test("an option needing an unbilled device is unpriceable and skipped")
    func unpriceableOptionSkipped() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [
                ("unknown_device", [], [("shield_generator", 0, 1)]),
                ("known", [("conductive", 0, 100)], []),
            ])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 100)
        #expect(demand.pricedEvents["E-1"]?.map(\.name) == ["known"])
    }

    @Test("an event with no priceable option contributes nothing")
    func whollyUnpriceableEvent() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("only", [], [("shield_generator", 0, 1)])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total.isEmpty)
        #expect(demand.pricedEvents["E-1"] == nil)
    }

    @Test("a closed event contributes nothing")
    func closedEventIgnored() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", status: "completed", options: [("default", [("conductive", 0, 100)], [])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total.isEmpty)
    }

    @Test("reserve floors are folded in as recurring print demand")
    func reserveFloorsFoldedIn() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [("conductive", 0, 100)], [])])],
            bills: [:],
            reserveFloors: ["conductive": 600, "volatiles": 50]
        )
        #expect(demand.total["conductive"] == 700)
        #expect(demand.total["volatiles"] == 50)
    }
}
