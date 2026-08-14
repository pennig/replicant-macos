//
//  LocationEventChoiceTests.swift
//  Replicould — LocationEventsFeature
//
//  The operator's fulfilment pick: which option the convoy is to satisfy.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import LocationEventsFeature

@Suite("Location events — option picker")
@MainActor
struct LocationEventChoiceTests {
    nonisolated private static func twoOptionEvent(_ designation: String, location: String) -> LocationEvent {
        LocationEvent(
            designation: designation, location: location, tier: 2, status: "active",
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
                        "devices": .array([]),
                        "resources": .object(["conductive": .number(150)]),
                    ]),
                ]),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func store(_ database: any DatabaseWriter) -> TestStoreOf<LocationEventsFeature> {
        let store = TestStore(initialState: LocationEventsFeature.State()) {
            LocationEventsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off
        return store
    }

    /// A second, unrelated event is in the table: the pick must land on the
    /// named row and leave the other undecided.
    @Test func choosingRecordsThePickOnTheNamedEventOnly() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try LocationEvent.insert { Self.twoOptionEvent("X-1-EVT-001", location: "X-1") }.execute(db)
            try LocationEvent.insert { Self.twoOptionEvent("Y-2-EVT-009", location: "Y-2") }.execute(db)
        }
        let store = Self.store(database)

        await store.send(.chooseOption(designation: "X-1-EVT-001", name: "booster"))
        await store.finish()

        let rows = try await database.read { db in try LocationEvent.all.fetchAll(db) }
        #expect(rows.first { $0.designation == "X-1-EVT-001" }?.chosenOption == "booster")
        #expect(rows.first { $0.designation == "Y-2-EVT-009" }?.chosenOption == nil)
    }

    /// Three pick states, three sentences. The stale one is the case a
    /// nil-check alone gets wrong: a pick naming an option the payload does not
    /// offer leaves every row unchosen and the event still pending.
    @Test func thePromptReadsCorrectlyForAllThreePickStates() {
        let options = Self.twoOptionEvent("X-1-EVT-001", location: "X-1").quest?.options ?? []
        #expect(options.count == 2)

        let undecided = EventOptionPicker.prompt(chosenOption: nil, options: options)
        let live = EventOptionPicker.prompt(chosenOption: "booster", options: options)
        let stale = EventOptionPicker.prompt(chosenOption: "gone", options: options)

        #expect(undecided.contains("No option chosen"))
        #expect(live == "The convoy delivers the chosen option.")
        #expect(stale.contains("no longer offered"))
        #expect(stale != live)
        #expect(stale != undecided)
    }

    /// The operator may change their mind before the convoy launches.
    @Test func choosingAgainReplacesThePick() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try LocationEvent.insert { Self.twoOptionEvent("X-1-EVT-001", location: "X-1") }.execute(db)
        }
        let store = Self.store(database)

        await store.send(.chooseOption(designation: "X-1-EVT-001", name: "booster"))
        await store.finish()
        await store.send(.chooseOption(designation: "X-1-EVT-001", name: "satellite"))
        await store.finish()

        let row = try await database.read { db in
            try LocationEvent.where { $0.designation.eq("X-1-EVT-001") }.fetchOne(db)
        }
        #expect(row?.chosenOption == "satellite")
    }
}
