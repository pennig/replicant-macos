//
//  MultiTheatreHaulTests.swift
//  Replicould — DirectiveEngine
//
//  Haul assignment across theatres: a pile in another mesh component is never
//  a candidate, and within one component distance beats raw size.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

private let positions: [String: Position] = [
    "AINALRAM": Position(x: -11.25, y: -37.09, z: -7.68),
    "GRAZ": Position(x: -14.0, y: -30.0, z: -5.0),
    "SOL": Position(x: 0, y: 0, z: 0),
    "OMEROPE": Position(x: -291.87, y: -125.98, z: 106.32),
]

private let components: [String: String] = [
    "AINALRAM": "AINALRAM", "GRAZ": "AINALRAM", "SOL": "AINALRAM",
    "OMEROPE": "OMEROPE",
]

/// Mirrors the `device` fixture helper in `HaulTargetPlannerTests.swift` — built
/// off `Device`'s real memberwise initializer rather than a guessed subset.
private func controller(_ code: String) -> Device {
    Device(
        deviceCode: code, deviceType: "ami_transport_controller", replicantCode: "R1",
        status: "coordinating", location: "AINALRAM-BELT-1", locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: ["ami"], tags: ["auto:haul"], detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 1_000), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Multi-theatre haul")
struct MultiTheatreHaulTests {
    @Test("A pile in another component is never assigned — the 316 ly regression")
    func refusesOtherComponent() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["OMEROPE-BELT-1": 50_000],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.isEmpty)
    }

    @Test("Two theatres in ONE component each drain their own nearer piles")
    func sharedComponentSplitsByDistance() {
        let near = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["GRAZ-1-L4": 1_000, "SOL-3-1": 1_000],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(near.first?.location == "GRAZ-1-L4")
    }

    @Test("A rich distant pile loses to a modest near one")
    func distanceBeatsRawSize() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["SOL-3-1": 1_200, "GRAZ-1-L4": 300],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "GRAZ-1-L4")
    }

    @Test("A pile large enough to pay for the trip still wins")
    func sizeStillWinsWhenItPays() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["SOL-3-1": 500_000, "GRAZ-1-L4": 300],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "SOL-3-1")
    }

    @Test("An in-system pile outranks every interstellar one and stays a shuttle")
    func shuttleOutranksFerry() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["AINALRAM-BELT-2": 10, "SOL-3-1": 500_000],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "AINALRAM-BELT-2")
        #expect(assignments.first?.directive == HaulTargetPlanner.shuttle)
    }

    @Test("An unplaceable pile falls back to raw units rather than vanishing")
    func unplaceableFallsBack() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["GHOST-1-L4": 9_000],
            components: components.merging(["GHOST": "AINALRAM"]) { a, _ in a },
            positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "GHOST-1-L4")
    }
}
