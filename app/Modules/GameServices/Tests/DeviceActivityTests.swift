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

    /// `in_control_range` lands in the detail tail and reads back through the
    /// accessor; `false` is the only state flagged as out of range (a missing
    /// field stays nil / not-out-of-range).
    @Test func inControlRangeReadsFromDetail() {
        var device = drone(status: "idle")

        device.detail = .object(["in_control_range": .bool(true)])
        #expect(device.inControlRange == true)
        #expect(device.isOutOfControlRange == false)

        device.detail = .object(["in_control_range": .bool(false)])
        #expect(device.inControlRange == false)
        #expect(device.isOutOfControlRange == true)

        device.detail = .object([:])
        #expect(device.inControlRange == nil)
        #expect(device.isOutOfControlRange == false)
    }

    /// A `scanning` drone's scan block is a body scan.
    @Test func scanningDeviceDerivesSurveyScan() {
        #expect(drone(status: "scanning").derivedActivity?.kind == .surveyScan)
    }

    /// A `searching` drone's identical scan block is a belt search.
    @Test func searchingDeviceDerivesSearch() {
        #expect(drone(status: "searching").derivedActivity?.kind == .search)
    }

    /// The eta_seconds countdown seeds the deadline off the fetch event-time (the
    /// fallback used when the server omits `completes_at`).
    @Test func scanBlockDeadlineFromEta() {
        let activity = drone(status: "scanning").derivedActivity
        #expect(activity?.completesAt == Date(timeIntervalSince1970: 1_000).addingTimeInterval(147))
    }

    /// The scan block now reports an absolute `completes_at`; it must win over the
    /// derived `eta_seconds` deadline (both `derivedActivity` and the
    /// `activityDeadline` re-arm), so a slightly-stale eta can't end the op early.
    @Test func scanBlockPrefersCompletesAtOverEta() {
        var device = drone(status: "scanning")
        let completesAt = "2026-07-01T02:45:00Z"
        let expected = try! Date(completesAt, strategy: .iso8601)
        device.detail = .object([
            "scan": .object([
                "progress_percent": .number(50),
                "started_at": .string("2026-07-01T02:40:58Z"),
                "target": .string("ATIANFU-1"),
                "eta_seconds": .number(147),          // would derive an earlier, staler deadline
                "completes_at": .string(completesAt),
            ]),
        ])
        #expect(device.derivedActivity?.completesAt == expected)
        #expect(device.activityDeadline == expected)
    }
}
