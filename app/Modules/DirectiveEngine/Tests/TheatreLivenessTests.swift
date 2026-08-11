//
//  TheatreLivenessTests.swift
//  Replicould — DirectiveEngine
//
//  Liveness is scoped per (kind, theatre); the device guard stays account-wide.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

private let livenessNow = Date(timeIntervalSince1970: 12_000)

private func livenessDatabase() throws -> any DatabaseWriter {
    try GameDatabase.bootstrap()
}

private func snapshot(_ database: any DatabaseWriter) async throws -> Brain.Snapshot {
    try await database.read { db in
        Brain.Snapshot(
            view: try WorldView.read(from: db, now: livenessNow),
            directives: try Directive.all.fetchAll(db),
            log: [:], hubFootprint: nil
        )
    }
}

@Suite("Theatre liveness")
struct TheatreLivenessTests {
    @Test("A live row in one theatre does not suppress the other's")
    func perTheatreLiveness() async throws {
        let database = try livenessDatabase()
        let home = Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                           readiness: .operational, stock: 40_000)
        let pocket = Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                             readiness: .operational, stock: 900)

        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D-HOME", kind: .haulRun, theatreDepot: home.depot)
            }.execute(db)
        }

        let brain = Brain(now: livenessNow)
        await brain.ensureOne(
            .haulRun, theatre: pocket, snapshot: try await snapshot(database), database: database
        ) {
            directiveFixture(id: "D-POCKET", kind: .haulRun, deviceCode: "T2", theatreDepot: pocket.depot)
        }

        let rows = try await database.read { try Directive.all.fetchAll($0) }
        #expect(Set(rows.map(\.id)) == ["D-HOME", "D-POCKET"])
    }

    @Test("A live row in the SAME theatre still suppresses a second")
    func sameTheatreStillSingleton() async throws {
        let database = try livenessDatabase()
        let home = Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                           readiness: .operational, stock: 40_000)

        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D-HOME", kind: .haulRun, theatreDepot: home.depot)
            }.execute(db)
        }

        let brain = Brain(now: livenessNow)
        await brain.ensureOne(
            .haulRun, theatre: home, snapshot: try await snapshot(database), database: database
        ) {
            directiveFixture(id: "D-SECOND", kind: .haulRun, deviceCode: "T2", theatreDepot: home.depot)
        }

        let rows = try await database.read { try Directive.all.fetchAll($0) }
        #expect(rows.map(\.id) == ["D-HOME"])
    }

    @Test("A device already committed elsewhere is refused even in a fresh theatre")
    func reservationGuardStaysAccountWide() async throws {
        let database = try livenessDatabase()
        let pocket = Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                             readiness: .operational, stock: 900)

        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D-HOME", kind: .salvageRun, deviceCode: "T1",
                                 theatreDepot: "AINALRAM-BELT-1")
            }.execute(db)
        }

        let brain = Brain(now: livenessNow)
        await brain.ensureOne(
            .haulRun, theatre: pocket, snapshot: try await snapshot(database), database: database
        ) {
            directiveFixture(id: "D-POCKET", kind: .haulRun, deviceCode: "T1", theatreDepot: pocket.depot)
        }

        let rows = try await database.read { try Directive.all.fetchAll($0) }
        #expect(rows.map(\.id) == ["D-HOME"])
    }
}
