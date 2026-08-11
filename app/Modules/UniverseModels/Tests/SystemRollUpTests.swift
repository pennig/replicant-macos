//
//  SystemRollUpTests.swift
//  UniverseModels
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SystemRollUpTests {
    /// One device and one holding in every container a system has: a belt, a
    /// planet, a moon, a Lagrange point and a structure.
    private var system: StarSystem {
        func device(_ code: String) -> LocatedDevice {
            LocatedDevice(deviceCode: code, deviceType: "miner")
        }
        func stock(_ quantity: Double) -> [InventoryItem] {
            [InventoryItem(resourceType: "iron", quantity: quantity)]
        }
        return StarSystem(
            designation: "SOL", systemScanned: true,
            belts: [
                Belt(
                    designation: "SOL-BELT-1",
                    sites: [ResourceSite(designation: "SOL-BELT-1-SITE-1")],
                    inventory: stock(1), devices: [device("BELT")]
                )
            ],
            planets: [
                Planet(
                    designation: "SOL-3",
                    moons: [
                        Moon(
                            designation: "SOL-3-1",
                            sites: [ResourceSite(designation: "SOL-3-1-SITE-1")],
                            salvage: [SalvageSite(designation: "SOL-3-1-SAL-1")],
                            devices: [device("MOON")], inventory: stock(2)
                        )
                    ],
                    sites: [ResourceSite(designation: "SOL-3-SITE-1")],
                    salvage: [SalvageSite(designation: "SOL-3-SAL-1")],
                    devices: [device("PLANET")], inventory: stock(4),
                    lagrange: [
                        SpecialSite(
                            designation: "SOL-3-L4", kind: .lagrange,
                            inventory: stock(8), devices: [device("LPOINT")]
                        )
                    ]
                )
            ],
            structures: [
                SpecialSite(
                    designation: "SOL-MEGA-1", kind: .megastructure,
                    inventory: stock(16), devices: [device("STRUCT")]
                )
            ]
        )
    }

    /// Every container that can host a device is counted — belts and structures
    /// and Lagrange points included, which the system row used to miss while the
    /// planet row beneath it already counted its own Lagrange points.
    @Test func allDevicesCountsEveryContainer() {
        #expect(
            system.allDevices.map(\.deviceCode).sorted()
                == ["BELT", "LPOINT", "MOON", "PLANET", "STRUCT"]
        )
    }

    @Test func allInventoryCountsEveryContainer() {
        // 1 + 2 + 4 + 8 + 16 — a distinct power per container, so a missing one
        // is legible in the total rather than merely wrong.
        #expect(system.totalInventoryQuantity == 31)
        #expect(system.allInventory.count == 5)
    }

    @Test func siteAndSalvageRollUpsAreUnchanged() {
        #expect(system.allResourceSites.count == 3)
        #expect(system.allSalvageSites.count == 2)
    }

    /// The stored summary must agree with the accessors it is built from — it is
    /// the read path for every collapsed row, and nothing else recomputes it.
    @Test func summaryAgreesWithTheAccessors() {
        let summary = SystemSummary(system)
        #expect(summary.deviceCount == system.allDevices.count)
        #expect(summary.siteCount == system.allResourceSites.count)
        #expect(summary.salvageCount == system.allSalvageSites.count)
        #expect(summary.shopCount == system.shops.count)
        #expect(summary.inventoryTotal == system.totalInventoryQuantity)
        #expect(summary.planetCount == system.planets.count)
        #expect(summary.hasChildren)
    }

    /// A system with nothing under it reports no children, so its row draws no
    /// chevron and nobody pays a decode to discover that.
    @Test func aBareSystemHasNoChildren() {
        let bare = StarSystem(designation: "RIGEL", systemScanned: true)
        #expect(!SystemSummary(bare).hasChildren)
    }

    /// A row round-trips through the persisted column with its summary intact.
    @Test func theSummarySurvivesThePersistedRow() throws {
        let row = try SystemDetail(system: system, hydratedAt: .distantPast)
        #expect(row.summaryJSON != nil)
        #expect(try row.summary() == SystemSummary(system))
    }

    /// A row written before the column existed still answers, by decoding.
    @Test func aRowWithNoStoredSummaryFallsBackToTheBlob() throws {
        var row = try SystemDetail(system: system, hydratedAt: .distantPast)
        row.summaryJSON = nil
        #expect(try row.summary() == SystemSummary(system))
    }
}
