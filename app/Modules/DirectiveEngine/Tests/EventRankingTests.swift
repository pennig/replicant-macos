import Foundation
import GameModels
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

@Suite("EventRanking")
struct EventRankingTests {
    private let costs: [String: ResourceCost] = [
        "defence_grid": ResourceCost(structural: 400),
        "comm_satellite": ResourceCost(structural: 350),
    ]

    private func event(
        _ designation: String, location: String, tier: Int,
        status: String = "active", met: Bool = false,
        resources: [String: Int] = ["structural": 200], options: Int = 1
    ) -> LocationEvent {
        let criteria = (0..<options).map { index in
            JSONValue.object([
                "name": .string(index == 0 ? "default" : "alt\(index)"),
                "devices": .array([]),
                "resources": .object(resources.mapValues { .number(Double($0)) }),
            ])
        }
        return LocationEvent(
            designation: designation, location: location, tier: tier, status: status,
            objectivesMet: met,
            detail: .object([
                "criteria": .array(criteria),
                "progress": .object([
                    "met": .bool(met), "replicant_present": .bool(false),
                    "options": .array([]),
                ]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    private let positions: [String: Position] = [
        "HUB": Position(x: 0, y: 0, z: 0),
        "NEAR": Position(x: 1, y: 0, z: 0),
        "FAR": Position(x: 10, y: 0, z: 0),
    ]

    @Test("already-met events outrank everything, then tier, then round trip")
    func order() {
        let events = [
            event("FAR-1-EVT-001", location: "FAR-1", tier: 4),
            event("NEAR-1-EVT-001", location: "NEAR-1", tier: 1),
            event("NEAR-2-EVT-001", location: "NEAR-2", tier: 1, met: true),
            event("NEAR-3-EVT-001", location: "NEAR-3", tier: 2),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.designation) == [
            "NEAR-2-EVT-001",  // already met
            "FAR-1-EVT-001",   // tier 4
            "NEAR-3-EVT-001",  // tier 2
            "NEAR-1-EVT-001",  // tier 1
        ])
    }

    @Test("a tie on tier breaks on round-trip cost then designation")
    func tieBreak() {
        let events = [
            event("FAR-1-EVT-001", location: "FAR-1", tier: 1),
            event("NEAR-1-EVT-001", location: "NEAR-1", tier: 1),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.designation) == ["NEAR-1-EVT-001", "FAR-1-EVT-001"])
        #expect(ranked[0].roundTripSeconds == 2 * 1 * EventRanking.secondsPerLy)
    }

    @Test("inactive, excluded, undecided and undecodable events are not candidates")
    func excluded() {
        let events = [
            event("A-1-EVT-001", location: "NEAR-1", tier: 1, status: "completed"),
            event("B-1-EVT-001", location: "NEAR-1", tier: 1),
            event("C-1-EVT-001", location: "NEAR-1", tier: 1, options: 2),
            LocationEvent(
                designation: "D-1-EVT-001", location: "NEAR-1", status: "active",
                detail: .object([:]), firstSeenAt: .distantPast, updatedAt: .distantPast
            ),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: ["B-1-EVT-001"]
        )
        #expect(ranked.isEmpty)
    }

    @Test("a recorded choice makes a multi-option event a candidate")
    func choiceAdmits() {
        let events = [event("C-1-EVT-001", location: "NEAR-1", tier: 1, options: 2)]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: ["C-1-EVT-001": "alt1"], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.option.name) == ["alt1"])
    }

    @Test("pendingChoices lists only undecided multi-option active events")
    func pending() {
        let events = [
            event("C-1-EVT-001", location: "NEAR-1", tier: 1, options: 2),
            event("D-1-EVT-001", location: "NEAR-1", tier: 1, options: 3),
            event("E-1-EVT-001", location: "NEAR-1", tier: 1),
        ]
        let pending = EventRanking.pendingChoices(
            events: events, chosenOptions: ["C-1-EVT-001": "alt1"], bills: costs
        )
        #expect(pending.map(\.0.designation) == ["D-1-EVT-001"])
        #expect(pending.first?.1.count == 3)
    }

    @Test("an event whose system the census cannot place still ranks, cost last")
    func unplaceable() {
        let events = [
            event("GHOST-1-EVT-001", location: "GHOST-1", tier: 1),
            event("NEAR-1-EVT-001", location: "NEAR-1", tier: 1),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.designation) == ["NEAR-1-EVT-001", "GHOST-1-EVT-001"])
    }

    @Test("an event whose every option needs an unknown blueprint is not ranked")
    func blockedIsNotRanked() {
        let row = eventNeeding(devices: [(2, "climate_processor")])
        let ranked = EventRanking.rank(
            events: [row], chosenOptions: [:], bills: ["climate_processor": ResourceCost(structural: 200)],
            components: ["climate_processor": ["orbital_mirror": 1]],
            positions: [:], depot: "HUB-1", excluding: []
        )
        #expect(ranked.isEmpty)
    }

    @Test("a blocked event is reported with the blueprints it lacks")
    func blockedIsReported() {
        let row = eventNeeding(devices: [(2, "climate_processor")])
        let blocked = EventRanking.blockedEvents(
            events: [row],
            bills: ["climate_processor": ResourceCost(structural: 200)],
            components: ["climate_processor": ["orbital_mirror": 1, "terraform_controller": 1]]
        )
        #expect(blocked.count == 1)
        #expect(blocked.first?.1.first?.unprintable == ["orbital_mirror", "terraform_controller"])
    }

    private func eventNeeding(devices: [(Int, String)]) -> LocationEvent {
        LocationEvent(
            designation: "TABAT-4-EVT-007", location: "TABAT-4", tier: 4, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("only"),
                    "devices": .array(devices.map {
                        .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
                    }),
                    "resources": .object([:]),
                ])]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }
}
