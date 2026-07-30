//
//  LocationEventTests.swift
//  LocationEventsFeatureTests
//
//  Parsing coverage for the quest payload — decoding a real `accounts/events`
//  entry into summary columns (`merging`) and the rich `LocationEventDetail`
//  (progress + rewards). Fixtures are captured verbatim from the live API.
//

import Foundation
import Testing
import Utils
@testable import GameModels

private func json(_ string: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
}

/// A resource-only quest (KRIOS-2-EVT-001), captured from `locations/KRIOS-2/events`.
private let resourceQuest = json(#"""
{
  "designation": "KRIOS-2-EVT-001",
  "location": "KRIOS-2",
  "location_name": null,
  "event_type": "medical_compound_request",
  "title": "Medical Compound Request",
  "description": "A pandemic is spreading...",
  "broadcast_message": "...millions are at risk...",
  "category": "resource_trade",
  "tier": 1,
  "status": "active",
  "discovered_at": "2026-07-03T21:12:09-05:00",
  "rewards": { "civilisation_points": 1, "completion_achievement": "medical_compound_completed", "resources": { "rares": 350 }, "xp": 600 },
  "criteria": [ { "devices": [], "name": "default", "resources": { "carbon": 250, "silicates": 100 } } ],
  "progress": {
    "met": false, "met_option": null, "replicant_present": false,
    "options": [ { "met": false, "name": "default", "devices": [],
      "resources": [
        { "met": false, "current": 40, "resource_type": "carbon", "required": 250 },
        { "met": false, "current": 0, "resource_type": "silicates", "required": 100 }
      ] } ]
  }
}
"""#)

/// A device-requiring quest (SOL-3-EVT-002), captured from `accounts/events`.
private let deviceQuest = json(#"""
{
  "designation": "SOL-3-EVT-002",
  "location": "SOL-3",
  "event_type": "rikers_lift",
  "title": "Riker's Lift",
  "category": "community",
  "tier": 3,
  "status": "active",
  "rewards": { "civilisation_points": 10, "xp": 15000, "completion_achievement": "rikers_lift_completed" },
  "progress": {
    "met": false, "replicant_present": false,
    "options": [ { "met": false, "name": "default",
      "devices": [ { "met": false, "current": 0, "required": 5, "device_type": "cargo_lifter" } ],
      "resources": [ { "met": false, "current": 0, "resource_type": "volatiles", "required": 80 } ] } ]
  }
}
"""#)

@Suite("LocationEvent parsing")
struct LocationEventParsingTests {
    @Test("Summary columns are lifted from the event payload")
    func summaryColumns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let event = LocationEvent.fresh(designation: "KRIOS-2-EVT-001", now: now)
            .merging(event: resourceQuest, now: now)

        #expect(event.location == "KRIOS-2")
        #expect(event.title == "Medical Compound Request")
        #expect(event.eventType == "medical_compound_request")
        #expect(event.category == "resource_trade")
        #expect(event.tier == 1)
        #expect(event.status == "active")
        #expect(event.isActive)
        #expect(event.discoveredAt != nil)
        #expect(event.firstSeenAt == now)
    }

    @Test("Resource progress decodes with live current/required")
    func resourceProgress() throws {
        let quest = try #require(LocationEventDetail(resourceQuest))
        #expect(!quest.met)
        #expect(quest.options.count == 1)

        let option = try #require(quest.options.first)
        #expect(option.resources.count == 2)
        let carbon = try #require(option.resources.first { $0.resourceType == "carbon" })
        #expect(carbon.current == 40)
        #expect(carbon.required == 250)
        #expect(!carbon.met)
        #expect(abs(carbon.fraction - 40.0 / 250.0) < 0.0001)
    }

    @Test("Rewards decode: XP, resources, civ points, achievement")
    func rewards() throws {
        let quest = try #require(LocationEventDetail(resourceQuest))
        #expect(quest.experiencePoints == 600)
        #expect(quest.civilisationPoints == 1)
        #expect(quest.completionAchievement == "medical_compound_completed")
        #expect(quest.rewardResources.count == 1)
        #expect(quest.rewardResources.first?.resourceType == "rares")
        #expect(quest.rewardResources.first?.amount == 350)
    }

    @Test("Device requirements decode alongside resources")
    func deviceRequirements() throws {
        let quest = try #require(LocationEventDetail(deviceQuest))
        let option = try #require(quest.options.first)
        #expect(option.devices.count == 1)
        let lifter = try #require(option.devices.first)
        #expect(lifter.deviceType == "cargo_lifter")
        #expect(lifter.required == 5)
        #expect(lifter.current == 0)
        #expect(quest.experiencePoints == 15000)
    }

    @Test("A blob without progress or rewards yields no quest detail")
    func emptyDetail() {
        #expect(LocationEventDetail(.object([:])) == nil)
    }

    @Test("Unmet objectives leave the event active, not ready")
    func objectivesUnmet() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let event = LocationEvent.fresh(designation: "KRIOS-2-EVT-001", now: now)
            .merging(event: resourceQuest, now: now)

        #expect(!event.objectivesMet)
        #expect(!event.isReady)
        #expect(event.displayStatus == "active")
    }

    @Test("Met objectives on an open event read as ready")
    func objectivesMetReady() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let metQuest = json(#"""
        {
          "designation": "KRIOS-2-EVT-001", "location": "KRIOS-2",
          "title": "Medical Compound Request", "status": "active", "tier": 1,
          "progress": { "met": true, "replicant_present": true, "options": [] }
        }
        """#)
        let event = LocationEvent.fresh(designation: "KRIOS-2-EVT-001", now: now)
            .merging(event: metQuest, now: now)

        #expect(event.objectivesMet)
        #expect(event.isReady)
        #expect(event.displayStatus == "ready")
    }

    @Test("A completed event is never ready even when objectives are met")
    func completedNotReady() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let doneQuest = json(#"""
        {
          "designation": "KRIOS-2-EVT-001", "location": "KRIOS-2",
          "status": "completed", "progress": { "met": true, "options": [] }
        }
        """#)
        let event = LocationEvent.fresh(designation: "KRIOS-2-EVT-001", now: now)
            .merging(event: doneQuest, now: now)

        #expect(event.objectivesMet)
        #expect(!event.isReady)
        #expect(event.displayStatus == "completed")
    }

    // MARK: Completion

    /// The `event.completed` payload closes the quest and leaves everything
    /// discovery captured — which the payload itself does not carry — intact.
    @Test("Completion closes the quest without erasing the discovered detail")
    func completionKeepsDiscoveredDetail() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let completedAt = Date(timeIntervalSince1970: 2_000_000)
        let discovered = LocationEvent.fresh(designation: "KRIOS-2-EVT-001", now: now)
            .merging(event: resourceQuest, now: now)

        let payload: [String: JSONValue] = [
            "designation": .string("KRIOS-2-EVT-001"),
            "rewards": .object(["xp": .number(450)]),
            "consumed": .object([
                "resources": .object(["volatiles": .number(80)]),
                "devices": .array([
                    .object([
                        "device_code": .string("60C33A33"),
                        "device_type": .string("cargo_lifter"),
                    ])
                ]),
            ]),
        ]
        let completed = discovered.completing(payload: payload, now: now, completedAt: completedAt)

        #expect(completed.status == "completed")
        #expect(completed.isCompleted)
        #expect(completed.objectivesMet)
        #expect(!completed.isReady)
        #expect(completed.completedAt == completedAt)
        #expect(completed.title == "Medical Compound Request")   // survived
        let quest = try #require(completed.quest)
        #expect(quest.experiencePoints == 450)
        #expect(quest.consumedResources.map(\.resourceType) == ["volatiles"])
        #expect(quest.consumedDevices.map(\.deviceCode) == ["60C33A33"])
        // The criteria discovery captured are still there to render against.
        #expect(!quest.options.isEmpty)
    }

    /// `accounts/events` never returns `consumed` — the stream is its only
    /// source. So the next authoritative refresh must not erase it, or the
    /// Consumed card would appear at completion and vanish moments later.
    @Test("A later authoritative refresh preserves the consumed manifest")
    func refreshPreservesConsumedManifest() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let payload: [String: JSONValue] = [
            "designation": .string("KRIOS-2-EVT-001"),
            "consumed": .object(["resources": .object(["volatiles": .number(80)])]),
        ]
        let completed = LocationEvent.fresh(designation: "KRIOS-2-EVT-001", now: now)
            .merging(event: resourceQuest, now: now)
            .completing(payload: payload, now: now, completedAt: nil)

        // The list entry the next refresh brings back carries no `consumed`.
        let refreshed = completed.merging(event: resourceQuest, now: now)

        #expect(refreshed.quest?.consumedResources.map(\.resourceType) == ["volatiles"])
    }

    /// …but an incoming block still wins, so the server stays authoritative if
    /// the list ever starts carrying one.
    @Test("An incoming consumed block overwrites the captured one")
    func incomingConsumedWins() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let completed = LocationEvent.fresh(designation: "KRIOS-2-EVT-001", now: now)
            .completing(
                payload: [
                    "consumed": .object(["resources": .object(["volatiles": .number(80)])])
                ],
                now: now,
                completedAt: nil
            )
        let authoritative = json(#"""
        {
          "designation": "KRIOS-2-EVT-001",
          "consumed": { "resources": { "carbon": 200 } }
        }
        """#)

        let refreshed = completed.merging(event: authoritative, now: now)
        #expect(refreshed.quest?.consumedResources.map(\.resourceType) == ["carbon"])
    }
}
