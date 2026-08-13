//
//  DepotInventorySweepTests.swift
//  Replicould — GameSync
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import GameSync

/// Mirrors the `device` fixture helper in `DirectiveEngine`'s
/// `HaulTargetPlannerTests.swift` — built off `Device`'s real memberwise
/// initializer rather than a guessed subset.
private func device(code: String, type: String, location: String?) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1",
        status: "idle", location: location, locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: type == "autofactory" ? ["enqueue_print"] : [],
        features: [], tags: [], detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Depot inventory sweep")
struct DepotInventorySweepTests {
    @Test("depots are the distinct locations of print-capable devices")
    func depotsArePrintHubLocations() {
        let devices = [
            device(code: "AAAA1111", type: "autofactory", location: "AINALRAM-BELT-1"),
            device(code: "BBBB2222", type: "autofactory", location: "AINALRAM-BELT-1"),
            device(code: "CCCC3333", type: "mining_drone", location: "OTHER-BELT-1"),
        ]
        #expect(DeadlineScheduler.depotLocations(in: devices) == ["AINALRAM-BELT-1"])
    }

    @Test("a print-capable device with no location contributes nothing")
    func stowedPrintHubIsSkipped() {
        let devices = [device(code: "AAAA1111", type: "autofactory", location: nil)]
        #expect(DeadlineScheduler.depotLocations(in: devices).isEmpty)
    }

    /// A failed device read degrades to a silent no-op — never a crash — per
    /// the sweep's "costs efficiency, never correctness" contract. A blank
    /// `DatabaseQueue` has none of `Device`'s tables, so the read genuinely fails.
    @Test("a failed device read is a silent no-op")
    func failedDeviceReadIsSilentNoOp() async throws {
        let blank = try DatabaseQueue()
        await withDependencies {
            $0.defaultDatabase = blank
        } operation: {
            await DeadlineScheduler(reconciler: Reconciler()).refreshDepotInventories()
        }
    }

    /// No print-capable device anywhere short-circuits before the network
    /// call — `locationsClient`'s unimplemented `testValue` would fail loudly
    /// if `body(_:)` were reached.
    @Test("no depots short-circuits before any client call")
    func noDepotsShortCircuits() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { device(code: "AAAA1111", type: "mining_drone", location: "SOL-3") }.execute(db)
        }
        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await DeadlineScheduler(reconciler: Reconciler()).refreshDepotInventories()
        }
    }

    @Test("never swept before is due")
    func neverSweptIsDue() {
        #expect(DeadlineScheduler.depotInventoryDue(
            lastAt: nil, now: Date(timeIntervalSince1970: 1_000), interval: 3600
        ))
    }

    @Test("inside the interval is not due")
    func insideIntervalIsNotDue() {
        let lastAt = Date(timeIntervalSince1970: 1_000)
        #expect(!DeadlineScheduler.depotInventoryDue(
            lastAt: lastAt, now: lastAt.addingTimeInterval(3599), interval: 3600
        ))
    }

    @Test("past the interval is due again")
    func pastIntervalIsDueAgain() {
        let lastAt = Date(timeIntervalSince1970: 1_000)
        #expect(DeadlineScheduler.depotInventoryDue(
            lastAt: lastAt, now: lastAt.addingTimeInterval(3600), interval: 3600
        ))
    }
}
