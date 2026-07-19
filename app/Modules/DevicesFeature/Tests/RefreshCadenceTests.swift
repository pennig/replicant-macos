//
//  RefreshCadenceTests.swift
//  Replicould — DevicesFeature
//
//  `DevicesFeature.refreshDelay(for:now:)` decides the while-viewing refresh
//  cadence: land just past a mining drone's next cycle boundary (so the re-read
//  sees the finished cycle's yield), tick a diverting propulsor slowly, and stop
//  the loop for anything settled. Pure function over a device snapshot.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices
@testable import DevicesFeature

@Suite struct RefreshCadenceTests {

    private let now = Date(timeIntervalSince1970: 1_000)

    /// A mining drone 10s into a 37s cycle → next boundary is 27s out, read 1.5s
    /// past it.
    @Test func miningRefreshesJustPastTheNextCycleBoundary() {
        let started = now.addingTimeInterval(-10)
        let device = miningDevice(startedAt: started, cycle: 37)
        #expect(DevicesFeature.refreshDelay(for: device, now: now) == .seconds(37 - 10 + 1.5))
    }

    /// Mining but with no cycle timing in the block → fall back to a modest poll.
    @Test func miningWithoutCycleTimingUsesModestPoll() {
        let device = device(status: "mining (structural)", detail: .object([:]))
        #expect(DevicesFeature.refreshDelay(for: device, now: now) == .seconds(20))
    }

    @Test func divertingTicksSlowly() {
        let device = device(status: "diverting", detail: .object([:]))
        #expect(DevicesFeature.refreshDelay(for: device, now: now) == .seconds(30))
    }

    @Test func repairingTicksModestly() {
        let device = device(status: "repairing (304F6EC1)", detail: .object([:]))
        #expect(DevicesFeature.refreshDelay(for: device, now: now) == .seconds(15))
    }

    @Test func settledDeviceStopsTheLoop() {
        #expect(DevicesFeature.refreshDelay(for: device(status: "idle", detail: .object([:])), now: now) == nil)
        #expect(DevicesFeature.refreshDelay(for: device(status: "stowed", detail: .object([:])), now: now) == nil)
    }

    // MARK: Builders

    private func miningDevice(startedAt: Date, cycle: Double) -> Device {
        device(status: "mining (structural)", detail: .object([
            "mining": .object([
                "started_at": .string(startedAt.ISO8601Format()),
                "cycle_time_seconds": .number(cycle),
                "resource_type": .string("structural"),
            ]),
        ]))
    }

    private func device(status: String, detail: JSONValue) -> Device {
        Device(
            deviceCode: "32658E70", deviceType: "mining_drone", replicantCode: "R1",
            status: status, location: "ATIANFU-BELT-1", locationName: nil,
            operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [],
            tags: [], detail: detail, updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
