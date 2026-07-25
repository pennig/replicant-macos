//
//  LocationsClientSalvageTests.swift
//  Replicould — GameServices
//
//  `mutateSalvage(atSite:)` is keyed by site designation specifically so that
//  depleting one salvage site never spends its siblings on the same body — the
//  bug this locks in: `mutateSalvage(atBody:)` used to run its transform over
//  every salvage site matching the body prefix. One line
//  (`guard salvage.designation == site else { return }`) is all that stands
//  between the fixed and regressed behavior, so it needs a direct test rather
//  than relying on the payload-parsing coverage in `SalvageEventPayloadTests`.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import GameServices

@Suite struct LocationsClientSalvageTests {
    /// TAANSI-6 hosting two live salvage sites, both undepleted with
    /// resources and percentages still present.
    private func systemWithTwoSalvageSites() -> StarSystem {
        StarSystem(
            designation: "TAANSI",
            planets: [Planet(
                designation: "TAANSI-6", recon: .scanned,
                salvage: [
                    SalvageSite(
                        designation: "TAANSI-6-SAL-1",
                        resourcesAvailable: ["conductive", "rares"],
                        depleted: false,
                        remainingPct: ["conductive": 80, "rares": 40]
                    ),
                    SalvageSite(
                        designation: "TAANSI-6-SAL-2",
                        resourcesAvailable: ["silicates"],
                        depleted: false,
                        remainingPct: ["silicates": 65]
                    ),
                ]
            )]
        )
    }

    @Test func markSalvageDepletedSpendsOnlyTheNamedSiteNotItsSibling() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_000)
        try await database.write { [system = systemWithTwoSalvageSites()] db in
            let row = try SystemDetail(system: system, hydratedAt: now)
            try SystemDetail.upsert { row }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
        } operation: {
            let changed = try await LocationsClient.liveValue.markSalvageDepleted(site: "TAANSI-6-SAL-1")
            #expect(changed == true)
        }

        let updated = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("TAANSI") }.fetchOne(db)
        }
        let system = try #require(try updated?.system())
        let sites = Dictionary(uniqueKeysWithValues: system.knownSalvageSites.map { ($0.designation, $0) })

        let targeted = try #require(sites["TAANSI-6-SAL-1"])
        #expect(targeted.depleted == true)
        #expect(targeted.resourcesAvailable.isEmpty)
        #expect(targeted.remainingPct == ["conductive": 0, "rares": 0])

        // The sibling site on the same body must be completely untouched.
        let sibling = try #require(sites["TAANSI-6-SAL-2"])
        #expect(sibling.depleted == false)
        #expect(sibling.resourcesAvailable == ["silicates"])
        #expect(sibling.remainingPct == ["silicates": 65])
    }
}
