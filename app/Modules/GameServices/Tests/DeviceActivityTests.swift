//
//  DeviceActivityTests.swift
//  Replicould — GameServices
//
//  A survey drone's body `scan` and belt `search` surface an identical `scan`
//  activity block, so `Device.derivedActivity` leans on the device status to tell
//  them apart when adopting an in-progress op from a cold snapshot.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct DeviceActivityTests {

    private func drone(status: String) -> Device {
        Device(
            deviceCode: "2586E328", deviceType: "survey_drone", replicantCode: "R1",
            status: status, location: "ATIANFU-1", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "scan": .object([
                    "progress_percent": .number(2),
                    "started_at": .string("2026-07-01T02:40:58Z"),
                    "target": .string("ATIANFU-1"),
                    "eta_seconds": .number(147),
                ]),
            ]),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// A `scanning` drone's scan block is a body scan.
    @Test func scanningDeviceDerivesSurveyScan() {
        #expect(drone(status: "scanning").derivedActivity?.kind == .surveyScan)
    }

    /// A `searching` drone's identical scan block is a belt search.
    @Test func searchingDeviceDerivesSearch() {
        #expect(drone(status: "searching").derivedActivity?.kind == .search)
    }

    /// The eta_seconds countdown seeds the deadline off the fetch event-time.
    @Test func scanBlockDeadlineFromEta() {
        let activity = drone(status: "scanning").derivedActivity
        #expect(activity?.completesAt == Date(timeIntervalSince1970: 1_000).addingTimeInterval(147))
    }
}
