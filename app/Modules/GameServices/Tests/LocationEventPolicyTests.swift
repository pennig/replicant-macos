//
//  LocationEventPolicyTests.swift
//  Replicould — GameServices
//
//  The passive-scan / roster-location policy behind the `locations.scan` relay
//  route: which events warrant a current-system re-scan, and which arrivals
//  advance the roster location. Pure logic, so exercised directly (no relay, no
//  database, no scan side effect).
//

import API
import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct LocationEventPolicyTests {

    // MARK: - Fixtures

    /// A relay `event` built from a payload dict (JSON-encoded like the wire).
    private func event(
        eventType: String,
        deviceCode: String? = nil,
        replicantCode: String? = nil,
        payload: [String: String] = [:]
    ) throws -> UnifiedEvent {
        var object: [String: Any] = ["type": "event", "timestamp": "2026-06-25T09:42:06-05:00"]
        object["event_type"] = eventType
        if let deviceCode { object["device_code"] = deviceCode }
        if let replicantCode { object["replicant_code"] = replicantCode }
        if !payload.isEmpty { object["payload"] = payload }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try UnifiedEvent(relayEvent: RelayEvent(id: "1-0", raw: data))
    }

    /// A replicant at ATIANFU-KUIPER hosted by vessel "HOST", by default.
    private func replicant(
        host: String? = "HOST",
        star: String? = "ATIANFU",
        location: String? = "ATIANFU-KUIPER",
        starName: String? = "Atianfu"
    ) -> Replicant {
        Replicant(
            replicantCode: "R1", name: "R", createdAt: Date(timeIntervalSince1970: 0),
            currentStar: star, currentStarName: starName,
            currentLocation: location, currentLocationName: "Kuiper",
            hostedDeviceCode: host
        )
    }

    // MARK: - system(for:)

    @Test func systemPrefersStarField() throws {
        let e = try event(eventType: "shop", payload: ["star": "ATIANFU", "location": "OTHER-1"])
        #expect(LocationEventPolicy.system(for: e) == "ATIANFU")
    }

    @Test func systemFallsBackToLocationPrefix() throws {
        let e = try event(eventType: "shop", payload: ["location": "ATIANFU-1-L4"])
        #expect(LocationEventPolicy.system(for: e) == "ATIANFU")
    }

    @Test func systemFallsBackToPlanetThenDesignation() throws {
        #expect(try LocationEventPolicy.system(for: event(eventType: "x", payload: ["planet": "SOL-3"])) == "SOL")
        #expect(try LocationEventPolicy.system(for: event(eventType: "x", payload: ["designation": "SOL-3-SAL-1"])) == "SOL")
    }

    @Test func systemIsNilWhenPayloadNamesNoPlace() throws {
        #expect(try LocationEventPolicy.system(for: event(eventType: "x", payload: ["status": "ok"])) == nil)
        #expect(try LocationEventPolicy.system(for: event(eventType: "x")) == nil)
    }

    // MARK: - Non-trigger events

    @Test func unrelatedEventIsIgnored() throws {
        let e = try event(eventType: "mining_started", deviceCode: "HOST", payload: ["location": "ATIANFU-KUIPER"])
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    // MARK: - Arrivals (host-device gated)

    @Test func hostArrivalCrossSystemScansAndAdvancesRosterClearingStarName() throws {
        let e = try event(eventType: "arrived", deviceCode: "HOST",
                          payload: ["star": "AINALRAM", "location": "AINALRAM-BELT-1"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == .init(star: "AINALRAM", location: "AINALRAM-BELT-1", systemChanged: true))
    }

    @Test func hostArrivalIntraSystemHopKeepsStarName() throws {
        // Same system (ATIANFU), different location → systemChanged false.
        let e = try event(eventType: "device_cruise_arrived", deviceCode: "HOST",
                          payload: ["location": "ATIANFU-1"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == .init(star: "ATIANFU", location: "ATIANFU-1", systemChanged: false))
    }

    @Test func hostArrivalDerivesStarFromLocationPrefixWhenAbsent() throws {
        let e = try event(eventType: "device_surge_hop_arrived", deviceCode: "HOST",
                          payload: ["location": "AINALRAM-1-L4"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.rosterUpdate?.star == "AINALRAM")
        #expect(decision.rosterUpdate?.location == "AINALRAM-1-L4")
        #expect(decision.rosterUpdate?.systemChanged == true)
    }

    @Test func hostArrivalAtSameLocationScansButDoesNotReWriteRoster() throws {
        let e = try event(eventType: "arrived", deviceCode: "HOST",
                          payload: ["star": "ATIANFU", "location": "ATIANFU-KUIPER"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)                 // still worth a passive refresh
        #expect(decision.rosterUpdate == nil)         // already there — no redundant write
    }

    @Test func arrivalOfAnotherDeviceIsIgnored() throws {
        // A mining drone (not the host vessel) arriving elsewhere leaves us put.
        let e = try event(eventType: "arrived", deviceCode: "DRONE",
                          payload: ["star": "ELSEWHERE", "location": "ELSEWHERE-2"])
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    @Test func arrivalWithNoDeviceCodeIsIgnored() throws {
        let e = try event(eventType: "arrived", payload: ["location": "AINALRAM-1"])
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    @Test func hostArrivalWithNoLocationScansWithoutRosterUpdate() throws {
        let e = try event(eventType: "arrived", deviceCode: "HOST", payload: ["status": "ok"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == nil)
    }

    // MARK: - Location-scoped events (current-system gated)

    @Test func locationEventInCurrentSystemScans() throws {
        let e = try event(eventType: "shop_restocked", payload: ["location": "ATIANFU-1"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == nil)   // location-scoped events never move the roster
    }

    @Test func locationEventInDifferentSystemIsIgnored() throws {
        let e = try event(eventType: "asteroid_incoming", payload: ["star": "SOMEWHERE"])
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    @Test func locationEventWithUnknownCurrentSystemIsIgnored() throws {
        let e = try event(eventType: "location_event", payload: ["location": "ATIANFU-1"])
        // Replicant has no current star → nothing to match against.
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant(star: nil)) == .ignore)
    }
}
