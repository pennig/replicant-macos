//
//  DiversionSnapshotTests.swift
//  Replicould — GameServices
//
//  `DiversionSnapshot(objectBlock:fallbackDesignation:)` parses the `object` block
//  of a `locations/{designation}` payload into the planetary-defense readout the
//  device inspector shows for a `diverting` propulsor. The device row itself
//  carries none of this — impact target/ETA/likelihood and deflection progress all
//  live on the object — so these tests pin the field mapping, the ISO-8601 date
//  parse, the fallback designation, and the reject cases for a non-`object` value.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct DiversionSnapshotTests {

    /// A real `object` block from a `locations/{OBJ}` read while a propulsor is
    /// diverting it: an incoming asteroid on course to strike a planet.
    private var objectBlock: JSONValue {
        .object([
            "designation": .string("ATIANFU-OBJ-1"),
            "object_type": .string("incoming_asteroid"),
            "size_class": .string("small"),
            "impact_target": .string("ATIANFU-1"),
            "impact_eta": .string("2026-07-08T17:36:31-05:00"),
            "impact_likelihood": .number(99.6),
            "progress_pct": .number(0.4),
            "required_strength": .number(24),
            "current_thrust_per_hour": .number(1),
            "active_plates": .number(1),
            "orbital_distance_au": .number(4.36),
            "status": .string("active"),
        ])
    }

    @Test func parsesEveryField() throws {
        let d = try #require(DiversionSnapshot(objectBlock: objectBlock, fallbackDesignation: "X"))
        #expect(d.objectDesignation == "ATIANFU-OBJ-1")
        #expect(d.objectType == "incoming_asteroid")
        #expect(d.sizeClass == "small")
        #expect(d.impactTarget == "ATIANFU-1")
        #expect(d.impactLikelihood == 99.6)
        #expect(d.progressPct == 0.4)
        #expect(d.requiredStrength == 24)
        #expect(d.currentThrustPerHour == 1)
        #expect(d.activePlates == 1)
        #expect(d.orbitalDistanceAu == 4.36)
        #expect(d.status == "active")
    }

    @Test func parsesImpactEtaAsOffsetTimestamp() throws {
        let d = try #require(DiversionSnapshot(objectBlock: objectBlock, fallbackDesignation: "X"))
        // 2026-07-08T17:36:31-05:00 == 2026-07-08T22:36:31Z.
        let expected = try Date("2026-07-08T22:36:31Z", strategy: .iso8601)
        #expect(d.impactEta == expected)
    }

    @Test func fallsBackToProvidedDesignationWhenBlockOmitsIt() throws {
        let block: JSONValue = .object(["object_type": .string("incoming_asteroid")])
        let d = try #require(DiversionSnapshot(objectBlock: block, fallbackDesignation: "ATIANFU-OBJ-2"))
        #expect(d.objectDesignation == "ATIANFU-OBJ-2")
    }

    @Test func optionalFieldsAreNilWhenAbsent() throws {
        let block: JSONValue = .object(["designation": .string("OBJ-9")])
        let d = try #require(DiversionSnapshot(objectBlock: block, fallbackDesignation: "X"))
        #expect(d.objectDesignation == "OBJ-9")
        #expect(d.impactTarget == nil)
        #expect(d.impactEta == nil)
        #expect(d.progressPct == nil)
    }

    @Test func returnsNilForNonObject() {
        #expect(DiversionSnapshot(objectBlock: .null, fallbackDesignation: "X") == nil)
        #expect(DiversionSnapshot(objectBlock: nil, fallbackDesignation: "X") == nil)
        #expect(DiversionSnapshot(objectBlock: .string("nope"), fallbackDesignation: "X") == nil)
    }
}
