//
//  DepotInventorySweepTests.swift
//  Replicould — GameSync
//

import Foundation
import GameModels
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
}
