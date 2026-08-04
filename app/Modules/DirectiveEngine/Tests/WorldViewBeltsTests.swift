//
//  WorldViewBeltsTests.swift
//  Replicould — DirectiveEngine
//
//  Task 11: `WorldView.beltsBySystem` hydrated from decoded belt data,
//  bounded to surveyed (`SystemDetail.systemScanned`) systems — the one
//  blob-decode boundary in the whole galaxy-wide read. Task 21 removed the
//  second bound (unmeshed); see `meshedSurveyedSystemBeltsAreIncluded`.
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

    /// Mesh status does NOT gate the decode (Task 21 — it used to).
    ///
    /// Prune is the second reader of this field and needs the belts of
    /// systems already REACHED: a perpetual mine belt is a live-value target
    /// forever, and the relay standing in it must stay on the path-union. A
    /// meshed system whose belts were invisible here would have its own relay
    /// read as useless — the one direction prune must never err in. Grow is
    /// unaffected, since `ValueCatalog.build` subtracts meshed systems itself
    /// (`ValueCatalogTests.meshedSystemsAreNotTargets`).
    ///
    /// Proven by ISOLATING the mesh variable: two systems carry the exact
    /// same classifiable belt and are both surveyed — the only difference is
    /// mesh status, and both now come through. `unsurveyedSystemExcluded`
    /// below is the sibling that proves the bound which DOES still gate the
    /// decode, so this pair together says "survey gates, mesh does not."
    @Test func meshedSurveyedSystemBeltsAreIncluded() async throws {
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
        #expect(view.beltsBySystem["VESTA"]?.first?.beltClass == .rich)
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
        #expect(!view.surveyedSystems.contains("HYGIEA"))
    }

    /// `surveyedSystems` is the same bound as the decode set, published so
    /// prune can tell "scanned, holds no belt" from "never scanned" — which
    /// `beltsBySystem` alone cannot, since both are absent from it. Both
    /// systems here are absent from `beltsBySystem` for exactly that pair of
    /// different reasons; only `surveyedSystems` separates them.
    @Test func surveyedSystemsSeparatesLookedAndFoundNothingFromNeverLooked() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStar(db, designation: "SCANNEDBARE", x: 8, y: 0, z: 0)
            try seedStar(db, designation: "NEVERSCANNED", x: 9, y: 0, z: 0)
            try seedSystemDetail(db, system: "SCANNEDBARE", scanned: true, belts: [])
            try seedSystemDetail(
                db, system: "NEVERSCANNED", scanned: false,
                belts: [Belt(designation: "NEVERSCANNED-2-BELT", density: "dense")]
            )
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem["SCANNEDBARE"] == nil)
        #expect(view.beltsBySystem["NEVERSCANNED"] == nil)
        #expect(view.surveyedSystems.contains("SCANNEDBARE"))
        #expect(!view.surveyedSystems.contains("NEVERSCANNED"))
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
