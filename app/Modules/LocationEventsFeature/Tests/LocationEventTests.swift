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
}
