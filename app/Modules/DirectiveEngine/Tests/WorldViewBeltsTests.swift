//
//  WorldViewBeltsTests.swift
//  Replicould — DirectiveEngine
//
//  Task 11: `WorldView.beltsBySystem` hydrated from decoded belt data,
//  bounded to surveyed (`SystemDetail.systemScanned`) and unmeshed systems —
//  the one blob-decode boundary in the whole galaxy-wide read.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("WorldView belts")
struct WorldViewBeltsTests {
    /// The brief's own scenario: a surveyed, unmeshed system's belt is
    /// decoded and classified.
    @Test func surveyedUnmeshedBeltsAreClassified() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStar(db, designation: "CERES", x: 4, y: 0, z: 0)
            try seedSystemDetail(
                db, system: "CERES", scanned: true,
                belts: [Belt(designation: "CERES-2-BELT", density: "dense")]
            )
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem["CERES"]?.first?.beltClass == .rich)
        #expect(view.beltsBySystem["CERES"]?.first?.designation == "CERES-2-BELT")
    }

    /// The cost-control guarantee, proven by ISOLATING the mesh variable: two
    /// systems carry the exact same classifiable belt and are both surveyed —
    /// the only difference is mesh status. If exclusion tracked anything else
    /// (a broken survey filter, decode always failing), both would come out
    /// the same way; only a real mesh-conditioned skip produces one belt and
    /// not the other. This is what makes it observable proof of SKIPPED work
    /// rather than a bare "key absent" assertion, which an unsurveyed system
    /// would produce identically for an unrelated reason.
    @Test func meshedSurveyedSystemBeltsAreExcluded() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStar(db, designation: "PALLAS", x: 1, y: 0, z: 0)
            try seedStar(db, designation: "VESTA", x: 2, y: 0, z: 0)
            try seedSystemDetail(
                db, system: "PALLAS", scanned: true,
                belts: [Belt(designation: "PALLAS-2-BELT", density: "dense")]
            )
            try seedSystemDetail(
                db, system: "VESTA", scanned: true,
                belts: [Belt(designation: "VESTA-2-BELT", density: "dense")]
            )
            // Only VESTA is meshed.
            try seedRelay(db, code: "R1", location: "VESTA-3-L4", status: "relaying")
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.meshSystems.contains("VESTA"))
        #expect(view.beltsBySystem["PALLAS"]?.first?.beltClass == .rich)
        #expect(view.beltsBySystem["VESTA"] == nil)
    }

    /// Belt richness is only known post-survey — an unsurveyed system's belt
    /// data (even if present in the blob) never reaches `beltsBySystem`.
    @Test func unsurveyedSystemExcluded() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStar(db, designation: "HYGIEA", x: 3, y: 0, z: 0)
            try seedSystemDetail(
                db, system: "HYGIEA", scanned: false,
                belts: [Belt(designation: "HYGIEA-2-BELT", density: "dense")]
            )
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem["HYGIEA"] == nil)
    }

    /// `BeltClass.classify` returning `nil` (unrecognised/absent density, no
    /// usable richness) must contribute no `BeltInfo` — proven against a
    /// SIBLING belt in the same system that DOES classify, so the missing one
    /// is provably due to its own unknown data and not some system-wide
    /// exclusion. This is the end-to-end case the previous task could only
    /// approximate with an empty-array proxy, now closed for real.
    @Test func unrecognisedBeltDensityContributesNoBeltInfo() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStar(db, designation: "JUNO", x: 5, y: 0, z: 0)
            try seedSystemDetail(
                db, system: "JUNO", scanned: true,
                belts: [
                    Belt(designation: "JUNO-2-BELT", density: "dense"),
                    Belt(designation: "JUNO-5-BELT", density: "molten", richness: [:]),
                ]
            )
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem["JUNO"]?.map(\.designation) == ["JUNO-2-BELT"])
    }

    /// A single malformed `systemJSON` blob degrades locally — the read must
    /// not throw galaxy-wide over one bad row, and a good row elsewhere in
    /// the same read must still come through untouched.
    @Test func malformedBlobDegradesLocallyWithoutFailingTheRead() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStar(db, designation: "BROKEN", x: 6, y: 0, z: 0)
            try seedMalformedSystemDetail(db, system: "BROKEN")
            try seedStar(db, designation: "GOOD", x: 7, y: 0, z: 0)
            try seedSystemDetail(
                db, system: "GOOD", scanned: true,
                belts: [Belt(designation: "GOOD-2-BELT", density: "dense")]
            )
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem["BROKEN"] == nil)
        #expect(view.beltsBySystem["GOOD"]?.first?.beltClass == .rich)
    }
}
