//
//  HaulTargetPlannerTests.swift
//  Replicould — DirectiveEngine
//
//  The Haul Run's ranking and assignment rules (design spec §5).
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

private let fixtureNow = Date(timeIntervalSince1970: 1_000)

/// Mirrors the `device` fixture helper in `SalvageRunTests.swift` — built off
/// `Device`'s real memberwise initializer rather than a guessed subset.
private func device(
    _ code: String,
    type: String,
    location: String? = nil,
    status: String = "idle",
    features: [String] = [],
    tags: [String] = [],
    updatedAt: Date = fixtureNow
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1",
        status: status, location: location, locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: features, tags: tags, detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func controller(_ code: String) -> Device {
    device(
        code, type: "ami_transport_controller", location: "ATIANFU-1-L4",
        status: "coordinating", features: ["ami"], tags: ["auto:haul"]
    )
}

/// A relay that meshes its system: the `relay` FEATURE plus `relaying` status is
/// exactly the predicate `SalvageTargetPlanner.meshSystems` reads.
private func relay(at location: String) -> Device {
    device("RLY-\(location)", type: "ftl_relay", location: location, status: "relaying", features: ["relay"])
}

private let delivery = "AINALRAM-BELT-1"

@Suite("Haul target planner")
struct HaulTargetPlannerTests {

    /// The headline: the richest reachable pile goes to the first controller.
    @Test func itPicksTheRichestReachablePile() {
        let mesh = SalvageTargetPlanner.meshSystems(in: [
            relay(at: "AINALRAM-1-L4"), relay(at: "ATIANFU-1-L4"), relay(at: "SHERATANON-10-L4"),
        ])
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1")],
            footprints: ["ATIANFU-BELT-1": 3_537, "SHERATANON-6-1": 294, "SHERATANON-7-4": 61],
            meshSystems: mesh,
            delivery: delivery
        )
        #expect(plans == [
            .init(controllerCode: "C1", location: "ATIANFU-BELT-1", directive: "ferry"),
        ])
    }

    /// The delivery location is never its own source — collecting from the place
    /// you deliver to is a no-op loop.
    @Test func itNeverCollectsFromTheDeliveryLocation() {
        let mesh = SalvageTargetPlanner.meshSystems(in: [relay(at: "AINALRAM-1-L4")])
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1")],
            footprints: [delivery: 59_230],
            meshSystems: mesh,
            delivery: delivery
        )
        #expect(plans.isEmpty)
    }

    /// An empty pile is not a candidate — this is also how a drained pile stops
    /// being worked, since nothing records "finished".
    @Test func itIgnoresEmptyPiles() {
        let mesh = SalvageTargetPlanner.meshSystems(in: [
            relay(at: "AINALRAM-1-L4"), relay(at: "ATIANFU-1-L4"),
        ])
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1")],
            footprints: ["ATIANFU-BELT-1": 0],
            meshSystems: mesh,
            delivery: delivery
        )
        #expect(plans.isEmpty)
    }

    /// Ferry's own requirement: an unmeshed system cannot be a source, however
    /// rich it is. TENEGSHE holds 80 units and no relay.
    @Test func itSkipsUnmeshedSystemsHoweverRich() {
        let mesh = SalvageTargetPlanner.meshSystems(in: [
            relay(at: "AINALRAM-1-L4"), relay(at: "SHERATANON-10-L4"),
        ])
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1")],
            footprints: ["TENEGSHE-3": 9_999, "SHERATANON-6-1": 294],
            meshSystems: mesh,
            delivery: delivery
        )
        #expect(plans == [
            .init(controllerCode: "C1", location: "SHERATANON-6-1", directive: "ferry"),
        ])
    }

    /// A pile in the delivery system uses `shuttle`, not `ferry` — a ferry whose
    /// two ends share a system is malformed.
    @Test func aPileInTheDeliverySystemUsesShuttle() {
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1")],
            footprints: ["AINALRAM-4": 500],
            meshSystems: [],
            delivery: delivery
        )
        #expect(plans == [
            .init(controllerCode: "C1", location: "AINALRAM-4", directive: "shuttle"),
        ])
    }

    /// Two controllers never share a pile — their drones would contend for the
    /// same units.
    @Test func controllersGetDistinctPilesInRankOrder() {
        let mesh = SalvageTargetPlanner.meshSystems(in: [
            relay(at: "AINALRAM-1-L4"), relay(at: "ATIANFU-1-L4"), relay(at: "SHERATANON-10-L4"),
        ])
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C2"), controller("C1")],
            footprints: ["ATIANFU-BELT-1": 3_537, "SHERATANON-6-1": 294, "SHERATANON-7-4": 61],
            meshSystems: mesh,
            delivery: delivery
        )
        // Controllers sort by code, so C1 takes the richest.
        #expect(plans == [
            .init(controllerCode: "C1", location: "ATIANFU-BELT-1", directive: "ferry"),
            .init(controllerCode: "C2", location: "SHERATANON-6-1", directive: "ferry"),
        ])
    }

    /// Surplus controllers get nothing rather than doubling up (spec §5).
    @Test func surplusControllersAreLeftUnassigned() {
        let mesh = SalvageTargetPlanner.meshSystems(in: [
            relay(at: "AINALRAM-1-L4"), relay(at: "ATIANFU-1-L4"),
        ])
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1"), controller("C2"), controller("C3")],
            footprints: ["ATIANFU-BELT-1": 3_537],
            meshSystems: mesh,
            delivery: delivery
        )
        #expect(plans.count == 1)
        #expect(plans.first?.controllerCode == "C1")
    }

    /// Equal piles resolve by designation, so the order is total and an
    /// evaluation never oscillates between two equally-rich candidates.
    @Test func equalPilesResolveByDesignation() {
        let mesh = SalvageTargetPlanner.meshSystems(in: [
            relay(at: "AINALRAM-1-L4"), relay(at: "ATIANFU-1-L4"),
        ])
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1"), controller("C2")],
            footprints: ["ATIANFU-BELT-2": 100, "ATIANFU-BELT-1": 100],
            meshSystems: mesh,
            delivery: delivery
        )
        #expect(plans.map(\.location) == ["ATIANFU-BELT-1", "ATIANFU-BELT-2"])
    }

    /// Nothing reachable is an empty plan — the machine reads that as idle, never
    /// as finished.
    @Test func nothingReachableYieldsNoAssignments() {
        let plans = HaulTargetPlanner.assignments(
            controllers: [controller("C1")],
            footprints: ["TENEGSHE-3": 80],
            meshSystems: [],
            delivery: delivery
        )
        #expect(plans.isEmpty)
    }
}
