//
//  BrainMineSeamTests.swift
//  Replicould — DirectiveEngine
//
//  The brain's mine goal end to end: one seeded world driven through the real
//  `report()`, and the two worlds that differ from it by exactly one fact.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

private let mineSeamNow = Date(timeIntervalSince1970: 900_000)
private let mineSeamHub = "SOL-3"
private let mineSeamBeltSystem = "VEGA"
private let mineSeamBelt = "VEGA-BELT-1"
private let mineSeamCarrier = "CARRIER1"

/// A meshed hub holding a complete printed `auto:mine` fleet and an idle
/// `auto:carrier`, plus a meshed, surveyed, dense belt one system out. Each flag
/// withdraws exactly one of those facts, which is what makes the twins twins.
private func seedMineSeamWorld(
    _ db: Database, printedFleet: Bool = true, beltSystemMeshed: Bool = true
) throws {
    try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
    try seedStar(db, designation: mineSeamBeltSystem, x: 5, y: 0, z: 0)
    try seedRelay(db, code: "RLY-SOL", location: "SOL-1")
    try seedPrintHub(db, code: "HUB1", location: mineSeamHub)
    try seedHubStockpile(
        db, location: mineSeamHub, resources: 1_000_000
    )
    try seedSystemDetail(
        db, system: mineSeamBeltSystem, scanned: true,
        belts: [Belt(designation: mineSeamBelt, density: "dense", richness: ["rares": "high"])]
    )
    if beltSystemMeshed {
        try seedRelay(db, code: "RLY-VEGA", location: "\(mineSeamBeltSystem)-1")
    }

    try seedDevice(
        db, code: mineSeamCarrier, type: MineRecipe.carrierDeviceType,
        location: mineSeamHub, tags: [MineRecipe.carrierTag.string], updatedAt: mineSeamNow
    )
    guard printedFleet else { return }
    for (type, quantity) in MineRecipe.all {
        for index in 0..<quantity {
            try seedDevice(
                db, code: "\(type)-\(index)", type: type, location: mineSeamHub,
                tags: [MineRecipe.fleetTag.string], updatedAt: mineSeamNow
            )
        }
    }
}

/// Two brain ticks over ONE uuid generator, returning the second tick's report.
/// Two because a report states its own tick's snapshot, so the launch the first
/// tick writes is only readable as `.launched` by the second.
private func driveMineSeam(_ database: any DatabaseWriter) async -> BrainReport {
    let uuid = UUIDGenerator.incrementing
    return await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(mineSeamNow)
        $0.uuid = uuid
        $0.deviceRefresher = confirmingRefresher(database)
    } operation: {
        _ = await Brain(now: mineSeamNow).report()
        return await Brain(now: mineSeamNow).report()
    }
}

private func mineSeamRuns(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in
        try Directive.where { $0.kind.eq(DirectiveKind.mineRun) }.fetchAll(db)
    }
}

@Suite("The brain's mine goal, end to end")
struct BrainMineSeamTests {
    /// The headline: a real tick over a real database writes a real `mineRun`
    /// row at the belt the planner chose, on the carrier the recipe found, and
    /// the why-view reads it back as launched.
    @Test func aBrainTickInstallsAMineAtTheMeshedBelt() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedMineSeamWorld(db) }

        let report = await driveMineSeam(database)

        let runs = try await mineSeamRuns(database)
        let launched = try #require(runs.first, "the brain launched no mine run")
        #expect(runs.count == 1)
        #expect(launched.deviceCode == mineSeamCarrier)
        #expect(launched.targets == [mineSeamBelt])
        #expect(launched.fleetTag == MineRecipe.fleetTag(forTheatre: mineSeamHub).string)
        // Without it the carrier stays at the belt and the next install prints one.
        #expect(launched.returnToOrigin)
        #expect(
            report.mine == .launched(vessel: mineSeamCarrier, focus: mineSeamBelt, status: .running)
        )
    }

    /// The first twin. Without it the headline would pass on a brain that
    /// launches at any belt regardless of what stands at the hub.
    @Test func withoutAPrintedFleetNothingLaunchesAndTheReportSaysWhy() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedMineSeamWorld(db, printedFleet: false) }

        let report = await driveMineSeam(database)

        #expect(try await mineSeamRuns(database).isEmpty)
        #expect(report.mine == .idle(reason: "no printed mine fleet"))
    }

    /// The second twin. The belt is still surveyed, dense and close — only the
    /// relay meshing its system is gone, which is the coupling to `tendMesh`
    /// that no unit test of the planner can prove.
    @Test func aBeltInAnUnmeshedSystemIsNotSitedAndTheReportSaysWhy() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedMineSeamWorld(db, beltSystemMeshed: false) }

        let report = await driveMineSeam(database)

        #expect(try await mineSeamRuns(database).isEmpty)
        #expect(report.mine == .idle(reason: "no meshed candidate belt"))
    }
}
