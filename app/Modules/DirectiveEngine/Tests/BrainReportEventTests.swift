//
//  BrainReportEventTests.swift
//  Replicould — DirectiveEngine
//
//  The pending event choices the why-view renders, priced against the fleet.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameSession
import SQLiteData
import Testing
import Utils
@testable import DirectiveEngine

private let choiceNow = Date(timeIntervalSince1970: 50_000)

private func fundedClient() -> GameClient {
    var client = GameClient.testValue
    client.budget = { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil) }
    return client
}

@Suite("Brain report — event choices")
struct BrainReportEventTests {
    @Test("a multi-option event surfaces with both options priced")
    func surfacesChoice() {
        let event = LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 2, status: "active",
            detail: .object([
                "criteria": .array([
                    .object([
                        "name": .string("satellite"),
                        "devices": .array([.object([
                            "count": .number(2), "device_type": .string("comm_satellite"),
                        ])]),
                        "resources": .object(["conductive": .number(150)]),
                    ]),
                    .object([
                        "name": .string("booster"),
                        "devices": .array([.object([
                            "count": .number(1), "device_type": .string("signal_booster"),
                        ])]),
                        "resources": .object(["conductive": .number(150)]),
                    ]),
                ]),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let choices = BrainReport.eventChoices(
            events: [event],
            bills: [
                "comm_satellite": ResourceCost(conductive: 350),
                "signal_booster": ResourceCost(conductive: 400),
            ],
            devices: [:]
        )
        #expect(choices.count == 1)
        #expect(choices[0].location == "X-1")
        #expect(choices[0].tier == 2)
        #expect(choices[0].options.map(\.name) == ["satellite", "booster"])
        #expect(choices[0].options[0].deviceUnits == 700)
        #expect(choices[0].options[1].deviceUnits == 400)
        #expect(choices[0].options.allSatisfy { $0.resourceUnits == 150 })
        #expect(choices[0].options.allSatisfy { !$0.exceedsOneFreighterLoad })
    }

    @Test("an event whose option is already picked is no longer offered")
    func decidedEventDropsOut() {
        var event = LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 2, status: "active",
            detail: .object([
                "criteria": .array([
                    .object(["name": .string("a"), "devices": .array([]), "resources": .object([:])]),
                    .object(["name": .string("b"), "devices": .array([]), "resources": .object([:])]),
                ]),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        #expect(BrainReport.eventChoices(events: [event], bills: [:], devices: [:]).count == 1)
        event.chosenOption = "b"
        #expect(BrainReport.eventChoices(events: [event], bills: [:], devices: [:]).isEmpty)
    }

    @Test("an option we already hold the devices for reports nothing missing")
    func reportsHeldDevices() {
        let event = LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 2, status: "active",
            detail: .object([
                "criteria": .array([
                    .object([
                        "name": .string("a"),
                        "devices": .array([.object([
                            "count": .number(1), "device_type": .string("signal_booster"),
                        ])]),
                        "resources": .object([:]),
                    ]),
                    .object([
                        "name": .string("b"),
                        "devices": .array([.object([
                            "count": .number(1), "device_type": .string("comm_satellite"),
                        ])]),
                        "resources": .object([:]),
                    ]),
                ]),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let held = EventRunFixtures.device("BOOST", type: "signal_booster")
        let spare = EventRunFixtures.device("HULL", type: "cargo_freighter")
        let choices = BrainReport.eventChoices(
            events: [event],
            bills: [
                "comm_satellite": ResourceCost(conductive: 350),
                "signal_booster": ResourceCost(conductive: 400),
            ],
            devices: ["BOOST": held, "HULL": spare]
        )
        #expect(choices[0].options[0].missingDevices.isEmpty)
        #expect(choices[0].options[1].missingDevices == ["comm_satellite"])
    }

    /// The report the why-view reads carries the choices from the same tick
    /// that read the events — not a later, separately-taken reading.
    @Test("the tick's report carries the pending choices")
    func theReportCarriesTheChoices() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try LocationEvent.insert {
                LocationEvent(
                    designation: "X-1-EVT-001", location: "X-1", tier: 2, status: "active",
                    detail: .object([
                        "criteria": .array([
                            .object([
                                "name": .string("a"), "devices": .array([]),
                                "resources": .object([:]),
                            ]),
                            .object([
                                "name": .string("b"), "devices": .array([]),
                                "resources": .object([:]),
                            ]),
                        ]),
                        "rewards": .object(["xp": .number(1500)]),
                    ]),
                    firstSeenAt: choiceNow, updatedAt: choiceNow
                )
            }.execute(db)
        }

        let report = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(choiceNow)
            $0.uuid = .incrementing
            $0.deviceRefresher = confirmingRefresher(database)
            $0.gameClient = fundedClient()
        } operation: {
            await Brain(now: choiceNow).report()
        }

        #expect(report.pendingEventChoices.map(\.designation) == ["X-1-EVT-001"])
        #expect(report.pendingEventChoices.first?.options.map(\.name) == ["a", "b"])
    }

    @Test("a blocked event reaches the why-view flagged, with its missing blueprints")
    func blockedReachesTheReport() {
        let row = LocationEvent(
            designation: "TABAT-4-EVT-007", location: "TABAT-4", tier: 4, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("only"),
                    "devices": .array([.object([
                        "count": .number(2), "device_type": .string("climate_processor"),
                    ])]),
                    "resources": .object([:]),
                ])]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let choices = BrainReport.eventChoices(
            events: [row],
            bills: ["climate_processor": ResourceCost(structural: 200)],
            components: ["climate_processor": ["orbital_mirror": 1, "terraform_controller": 1]],
            devices: [:]
        )
        #expect(choices.count == 1)
        #expect(choices.first?.isBlocked == true)
        #expect(choices.first?.options.first?.unprintable == ["orbital_mirror", "terraform_controller"])
    }
}
