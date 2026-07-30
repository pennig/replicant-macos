//
//  LocationEventsIngestionTests.swift
//  Replicould — LocationEventsFeature
//
//  The quest log's declared event route: the `event.*` family and a completed
//  scan nudge one debounced authoritative re-read; unrelated events don't.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import LocationEventsFeature

@Suite struct LocationEventsIngestionTests {

    private func event(_ name: String, payload: [String: JSONValue]? = nil) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: String(name.split(separator: ".").first ?? ""),
            event: name,
            payload: payload,
            createdAt: "2026-07-21T09:00:00Z"
        )
    }

    /// The `event.completed` payload as the live stream delivers it (read off
    /// the app's own SSE ledger).
    private var completionPayload: [String: JSONValue] {
        [
            "designation": .string("TENEGSHE-3-EVT-003"),
            "event_type": .string("refugee_evacuation"),
            "location": .string("TENEGSHE-3"),
            "tier": .number(2),
            "rewards": .object([
                "xp": .number(1_800),
                "civilisation_points": .number(3),
                "resources": .object(["carbon": .number(200), "rares": .number(300)]),
            ]),
            "consumed": .object([
                "resources": .object(["volatiles": .number(200)]),
                "devices": .array([
                    .object([
                        "device_code": .string("60C33A33"),
                        "device_type": .string("transport_drone"),
                    ]),
                    .object([
                        "device_code": .string("41A1B62E"),
                        "device_type": .string("transport_drone"),
                    ]),
                ]),
            ]),
        ]
    }

    private func seedQuest(_ database: any DatabaseWriter, now: Date) async throws {
        try await database.write { db in
            try LocationEvent.upsert {
                LocationEvent(
                    designation: "TENEGSHE-3-EVT-003",
                    location: "TENEGSHE-3",
                    eventType: "refugee_evacuation",
                    title: "Refugee Evacuation",
                    tier: 2,
                    status: "active",
                    objectivesMet: false,
                    eventDescription: "An environmental catastrophe…",
                    firstSeenAt: now,
                    updatedAt: now
                )
            }
            .execute(db)
        }
    }

    private func spy(into invalidated: LockIsolated<[FreshnessDomain]>) -> DomainFreshnessClient {
        DomainFreshnessClient(
            register: { _, _ in },
            invalidate: { domain in invalidated.withValue { $0.append(domain) } },
            refreshIfStale: { _ in },
            reset: {}
        )
    }

    @Test func questFamilyAndScanCompletionInvalidate() async {
        let invalidated = LockIsolated<[FreshnessDomain]>([])
        await withDependencies {
            $0.domainFreshness = spy(into: invalidated)
        } operation: {
            let route = LocationEventsIngestion.eventRoute
            await route.apply(event("event.discovered"))
            await route.apply(event("scan.completed"))
            await route.apply(event("mining.started"))    // unrelated — no nudge
            await route.apply(event("event.completed"))   // `completedRoute`'s job
        }
        #expect(invalidated.value == [.locationEvents, .locationEvents])
    }

    @Test func gapRepairInvalidatesUnconditionally() async {
        let invalidated = LockIsolated<[FreshnessDomain]>([])
        await withDependencies {
            $0.domainFreshness = spy(into: invalidated)
        } operation: {
            await LocationEventsIngestion.eventRoute.gapRepair()
        }
        #expect(invalidated.value == [.locationEvents])
    }

    // MARK: Completion

    /// Completion closes the row it names and folds in the rewards and the
    /// consumed manifest — without walking `accounts/events` to do it.
    @Test func completionClosesTheRowWithoutARefresh() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try await seedQuest(database, now: now)
        let invalidated = LockIsolated<[FreshnessDomain]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.domainFreshness = spy(into: invalidated)
            $0.date = .constant(now)
        } operation: {
            await LocationEventsIngestion.completedRoute.apply(
                event("event.completed", payload: completionPayload)
            )
        }

        let row = try await database.read { db in
            try LocationEvent.where { $0.designation.eq("TENEGSHE-3-EVT-003") }.fetchOne(db)
        }
        let quest = try #require(row?.quest)
        #expect(row?.status == "completed")
        #expect(row?.objectivesMet == true)
        #expect(row?.isActive == false)
        // Stamped from the envelope's own timestamp, not the local clock.
        #expect(row?.completedAt == ISO8601DateFormatter().date(from: "2026-07-21T09:00:00Z"))
        // Discovery's richer fields survive the thinner completion payload.
        #expect(row?.title == "Refugee Evacuation")
        #expect(row?.eventDescription == "An environmental catastrophe…")
        // Rewards and the consumed manifest are now available to render.
        #expect(quest.experiencePoints == 1_800)
        #expect(quest.civilisationPoints == 3)
        #expect(quest.rewardResources.map(\.resourceType) == ["carbon", "rares"])
        #expect(quest.consumedResources.map(\.resourceType) == ["volatiles"])
        #expect(quest.consumedResources.map(\.amount) == [200])
        #expect(quest.consumedDevices.map(\.deviceCode) == ["60C33A33", "41A1B62E"])
        #expect(quest.consumedDevices.allSatisfy { $0.deviceType == "transport_drone" })
        // The whole point: no authoritative walk.
        #expect(invalidated.value.isEmpty)
    }

    /// A quest we never held — discovery missed, or it closed elsewhere. The
    /// payload has no title or description, so fall back to the full list.
    @Test func completionOfAnUnknownQuestFallsBackToTheList() async throws {
        let database = try GameDatabase.bootstrap()
        let invalidated = LockIsolated<[FreshnessDomain]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.domainFreshness = spy(into: invalidated)
            $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
        } operation: {
            await LocationEventsIngestion.completedRoute.apply(
                event("event.completed", payload: completionPayload)
            )
        }

        #expect(invalidated.value == [.locationEvents])
        let count = try await database.read { db in try LocationEvent.fetchAll(db).count }
        #expect(count == 0)   // nothing blank was invented
    }

    /// A payload with no designation names no row — spend nothing on it.
    @Test func completionWithoutADesignationIsIgnored() async throws {
        let database = try GameDatabase.bootstrap()
        let invalidated = LockIsolated<[FreshnessDomain]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.domainFreshness = spy(into: invalidated)
            $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
        } operation: {
            await LocationEventsIngestion.completedRoute.apply(
                event("event.completed", payload: ["tier": .number(1)])
            )
        }
        #expect(invalidated.value.isEmpty)
    }

    /// An exact-name matcher, so the Event Log stops calling completion
    /// unhandled — the family route's `.all` never counted as specific.
    @Test func completedRouteMatchesByExactName() {
        let match = LocationEventsIngestion.completedRoute.match
        #expect(!match.isCatchAll)
        #expect(match.matches(event("event.completed")))
        #expect(!match.matches(event("event.discovered")))
    }
}
