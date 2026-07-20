//
//  EventLogFeatureTests.swift
//  Replicould — EventLogFeature
//
//  Covers the pieces with real logic: mapping a dispatched envelope into a log row,
//  reconstructing the full-envelope JSON for the detail tree, the "unhandled only"
//  query narrowing, and the destructive clear.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import SQLiteData
import Testing
import Utils
@testable import EventLogFeature
@testable import GameModels

@MainActor
@Suite struct EventLogFeatureTests {

    // MARK: - Fixtures

    private nonisolated static func handledRow(id: String, at t: TimeInterval) -> EventLog {
        EventLog(
            id: id, event: "mining.started", category: "mining",
            deviceCode: "VES-1", deviceType: "vessel",
            receivedAt: Date(timeIntervalSince1970: t),
            provenance: "stream", isHandled: true, matchedRoutes: "locations.scan",
            payload: .object(["resource": .string("iron_ore")])
        )
    }

    private nonisolated static func unhandledRow(id: String, at t: TimeInterval) -> EventLog {
        EventLog(
            id: id, event: "anomaly.detected", category: "anomaly",
            star: "KRIOS", location: "KRIOS-2",
            receivedAt: Date(timeIntervalSince1970: t),
            provenance: "stream", isHandled: false, matchedRoutes: nil,
            payload: .object([:])
        )
    }

    // MARK: - Envelope mapping

    @Test("An envelope maps into a log row, folding provenance and matched routes")
    func envelopeMapsToRow() {
        let envelope = GameEventEnvelope(
            id: "1-0", version: 2, category: "mining", event: "mining.started",
            replicantCode: "RPL-1", deviceCode: "VES-1", deviceType: "vessel",
            star: "SOL", location: "SOL-3",
            payload: ["resource": .string("iron_ore")],
            createdAt: "2026-07-20T09:00:00Z", provenance: .catchUp
        )

        let row = EventLog(
            envelope: envelope, isHandled: true,
            matchedRouteIDs: ["a", "b"], receivedAt: Date(timeIntervalSince1970: 10)
        )

        #expect(row.id == "1-0")
        #expect(row.event == "mining.started")
        #expect(row.category == "mining")
        #expect(row.deviceCode == "VES-1")
        #expect(row.provenance == "catchUp")
        #expect(row.isHandled)
        #expect(row.matchedRoutes == "a, b")
        #expect(row.payload["resource"]?.stringValue == "iron_ore")
    }

    @Test("An empty payload collapses to an empty object; no matched routes is nil")
    func envelopeMapsEmptyPayload() {
        let envelope = GameEventEnvelope(
            id: "2-0", category: "anomaly", event: "anomaly.detected",
            payload: nil, provenance: .stream
        )
        let row = EventLog(
            envelope: envelope, isHandled: false,
            matchedRouteIDs: [], receivedAt: Date(timeIntervalSince1970: 20)
        )
        #expect(row.provenance == "stream")
        #expect(row.matchedRoutes == nil)
        #expect(row.payload == .object([:]))
    }

    // MARK: - Detail JSON

    @Test("envelopeJSON folds metadata columns together with the nested payload")
    func envelopeJSONIncludesMetadataAndPayload() {
        let row = Self.handledRow(id: "3-0", at: 30)
        guard case let .object(object) = row.envelopeJSON else {
            Issue.record("expected an object")
            return
        }
        #expect(object["id"]?.stringValue == "3-0")
        #expect(object["event"]?.stringValue == "mining.started")
        #expect(object["category"]?.stringValue == "mining")
        #expect(object["provenance"]?.stringValue == "stream")
        #expect(object["device_code"]?.stringValue == "VES-1")
        // Absent metadata is omitted rather than rendered as null.
        #expect(object["location"] == nil)
        // The payload rides along nested under its own key.
        #expect(object["payload"]?["resource"]?.stringValue == "iron_ore")
    }

    // MARK: - Filter

    @Test("The unhandled-only query narrows to unhandled rows")
    func unhandledFilterNarrows() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try EventLog.insert {
                Self.handledRow(id: "h-1", at: 100)
                Self.unhandledRow(id: "u-1", at: 200)
            }
            .execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            @FetchAll(EventLog.order { $0.receivedAt.desc() }) var events: [EventLog]
            // Same query the reducer issues when the filter turns on.
            try await $events.load(
                EventLog.where { !$0.isHandled }.order { $0.receivedAt.desc() }
            )
            #expect(events.count == 1)
            #expect(events.first?.id == "u-1")
            #expect(events.allSatisfy { !$0.isHandled })
        }
    }

    // MARK: - Clear

    @Test("Confirming clear empties the table and resets selection")
    func clearEmptiesTable() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try EventLog.insert {
                Self.handledRow(id: "h-1", at: 100)
                Self.unhandledRow(id: "u-1", at: 200)
            }
            .execute(db)
        }

        let store = TestStore(initialState: EventLogFeature.State(selection: "u-1")) {
            EventLogFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        await store.send(.clearButtonTapped) { $0.isConfirmingClear = true }
        await store.send(.clearConfirmed) {
            $0.isConfirmingClear = false
            $0.selection = nil
        }
        await store.finish()

        let remaining = try await database.read { db in try EventLog.fetchCount(db) }
        #expect(remaining == 0)
    }
}
