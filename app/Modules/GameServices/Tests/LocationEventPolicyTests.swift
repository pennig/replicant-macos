//
//  LocationEventPolicyTests.swift
//  Replicould — GameServices
//
//  The passive-scan / roster-location policy behind the `locations.scan` route:
//  which events warrant a current-system re-scan, and which arrivals advance the
//  roster location. Pure logic, so exercised directly (no stream, no database,
//  no scan side effect).
//

import API
import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct LocationEventPolicyTests {

    // MARK: - Fixtures

    /// A game `event` with a dotted name. Place fields can be supplied either as
    /// first-class envelope fields (`star`/`location`) or in the `payload`, to
    /// exercise both resolution paths.
    private func event(
        _ name: String,
        deviceCode: String? = nil,
        replicantCode: String? = nil,
        star: String? = nil,
        location: String? = nil,
        payload: [String: String] = [:]
    ) -> GameEventEnvelope {
        let values = payload.mapValues { JSONValue.string($0) }
        return GameEventEnvelope(
            id: "1-0",
            category: String(name.split(separator: ".").first ?? ""),
            event: name,
            replicantCode: replicantCode,
            deviceCode: deviceCode,
            star: star,
            location: location,
            payload: values.isEmpty ? nil : values,
            createdAt: "2026-06-25T09:42:06-05:00"
        )
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

    @Test func systemPrefersEnvelopeStarField() {
        let e = event("shop.restocked", star: "ATIANFU", location: "OTHER-1")
        #expect(LocationEventPolicy.system(for: e) == "ATIANFU")
    }

    @Test func systemFallsBackToEnvelopeLocationPrefix() {
        let e = event("shop.restocked", location: "ATIANFU-1-L4")
        #expect(LocationEventPolicy.system(for: e) == "ATIANFU")
    }

    @Test func systemPrefersPayloadStarWhenEnvelopeAbsent() {
        let e = event("shop.restocked", payload: ["star": "ATIANFU", "location": "OTHER-1"])
        #expect(LocationEventPolicy.system(for: e) == "ATIANFU")
    }

    @Test func systemFallsBackToPayloadPlanetThenDesignation() {
        #expect(LocationEventPolicy.system(for: event("x", payload: ["planet": "SOL-3"])) == "SOL")
        #expect(LocationEventPolicy.system(for: event("x", payload: ["designation": "SOL-3-SAL-1"])) == "SOL")
    }

    @Test func systemIsNilWhenNothingNamesAPlace() {
        #expect(LocationEventPolicy.system(for: event("x", payload: ["status": "ok"])) == nil)
        #expect(LocationEventPolicy.system(for: event("x")) == nil)
    }

    // MARK: - Non-trigger events

    @Test func unrelatedEventIsIgnored() {
        let e = event("mining.started", deviceCode: "HOST", location: "ATIANFU-KUIPER")
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    // MARK: - Arrivals (host-device gated)

    @Test func hostArrivalCrossSystemScansAndAdvancesRosterClearingStarName() {
        // Arrival carries its place in the first-class envelope fields.
        let e = event("travel.arrived", deviceCode: "HOST", star: "AINALRAM", location: "AINALRAM-BELT-1")
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == .init(star: "AINALRAM", location: "AINALRAM-BELT-1", systemChanged: true))
    }

    @Test func hostArrivalIntraSystemHopKeepsStarName() {
        // Same system (ATIANFU), different location → systemChanged false.
        let e = event("travel.cruise_arrived", deviceCode: "HOST", location: "ATIANFU-1")
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == .init(star: "ATIANFU", location: "ATIANFU-1", systemChanged: false))
    }

    @Test func hostArrivalDerivesStarFromPayloadLocationPrefixWhenAbsent() {
        // Place supplied via payload (not envelope) → star derived from prefix.
        let e = event("travel.surge_hop_arrived", deviceCode: "HOST", payload: ["location": "AINALRAM-1-L4"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.rosterUpdate?.star == "AINALRAM")
        #expect(decision.rosterUpdate?.location == "AINALRAM-1-L4")
        #expect(decision.rosterUpdate?.systemChanged == true)
    }

    @Test func hostArrivalAtSameLocationScansButDoesNotReWriteRoster() {
        let e = event("travel.arrived", deviceCode: "HOST", star: "ATIANFU", location: "ATIANFU-KUIPER")
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)                 // still worth a passive refresh
        #expect(decision.rosterUpdate == nil)         // already there — no redundant write
    }

    @Test func arrivalOfAnotherDeviceIsIgnored() {
        // A mining drone (not the host vessel) arriving elsewhere leaves us put.
        let e = event("travel.arrived", deviceCode: "DRONE", star: "ELSEWHERE", location: "ELSEWHERE-2")
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    @Test func arrivalWithNoDeviceCodeIsIgnored() {
        let e = event("travel.arrived", location: "AINALRAM-1")
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    @Test func hostArrivalWithNoLocationScansWithoutRosterUpdate() {
        let e = event("travel.arrived", deviceCode: "HOST", payload: ["status": "ok"])
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == nil)
    }

    // MARK: - Location-scoped events (current-system gated)

    @Test func locationEventInCurrentSystemScans() {
        let e = event("shop.restocked", location: "ATIANFU-1")
        let decision = LocationEventPolicy.decide(event: e, replicant: replicant())
        #expect(decision.shouldScan)
        #expect(decision.rosterUpdate == nil)   // location-scoped events never move the roster
    }

    @Test func locationEventInDifferentSystemIsIgnored() {
        let e = event("system.object_detected", star: "SOMEWHERE")
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant()) == .ignore)
    }

    @Test func locationEventWithUnknownCurrentSystemIsIgnored() {
        let e = event("event.discovered_location_event", location: "ATIANFU-1")
        // Replicant has no current star → nothing to match against.
        #expect(LocationEventPolicy.decide(event: e, replicant: replicant(star: nil)) == .ignore)
    }
}
