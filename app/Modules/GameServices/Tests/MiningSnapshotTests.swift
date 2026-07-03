//
//  MiningSnapshotTests.swift
//  Replicould — GameServices
//
//  `MiningSnapshot(miningBlock:)` maps a mining drone's `mining` block to the
//  cycle-aware readout the inspector shows. The load-bearing bit is `isProducing`:
//  a completed cycle that yields resource leaves a positive `pending_*` tally
//  (mining), while a scarce belt that turns up nothing leaves both at 0 (seeking).
//  These tests pin the field mapping and that discriminator.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct MiningSnapshotTests {

    /// A real `mining` block from a drone working a scarce, dense belt.
    private var miningBlock: JSONValue {
        .object([
            "availability": .string("scarce"),
            "belt": .string("ATIANFU-BELT-1"),
            "density": .string("dense"),
            "started_at": .string("2026-07-01T22:36:30-05:00"),
            "cycle_time_seconds": .number(37),
            "pending_cycles": .number(0),
            "pending_quantity": .number(0),
            "resource_type": .string("structural"),
        ])
    }

    @Test func parsesEveryField() throws {
        let m = try #require(MiningSnapshot(miningBlock: miningBlock))
        #expect(m.resourceType == "structural")
        #expect(m.belt == "ATIANFU-BELT-1")
        #expect(m.density == "dense")
        #expect(m.availability == "scarce")
        #expect(m.cycleTimeSeconds == 37)
        #expect(m.pendingCycles == 0)
        #expect(m.pendingQuantity == 0)
    }

    @Test func parsesStartedAtAsOffsetTimestamp() throws {
        let m = try #require(MiningSnapshot(miningBlock: miningBlock))
        let expected = try Date("2026-07-02T03:36:30Z", strategy: .iso8601)
        #expect(m.startedAt == expected)
    }

    /// Both pending fields at 0 → the last cycle produced nothing → seeking.
    @Test func zeroPendingReadsAsSeeking() throws {
        let m = try #require(MiningSnapshot(miningBlock: miningBlock))
        #expect(m.isProducing == false)
    }

    /// A positive cycle tally → the drone extracted → mining.
    @Test func pendingCyclesReadsAsProducing() throws {
        var block = miningBlock
        if case .object(var dict) = block {
            dict["pending_cycles"] = .number(2)
            block = .object(dict)
        }
        let m = try #require(MiningSnapshot(miningBlock: block))
        #expect(m.isProducing == true)
    }

    /// A pending quantity with no whole cycles still counts as producing.
    @Test func pendingQuantityReadsAsProducing() throws {
        let m = try #require(MiningSnapshot(miningBlock: .object([
            "pending_cycles": .number(0),
            "pending_quantity": .number(5),
        ])))
        #expect(m.isProducing == true)
    }

    @Test func returnsNilForNonObject() {
        #expect(MiningSnapshot(miningBlock: nil) == nil)
        #expect(MiningSnapshot(miningBlock: .null) == nil)
        #expect(MiningSnapshot(miningBlock: .string("nope")) == nil)
    }

    @Test func deviceMiningSnapshotReadsTheMiningBlock() throws {
        let device = makeDevice(detail: .object(["mining": miningBlock]))
        let m = try #require(device.miningSnapshot)
        #expect(m.resourceType == "structural")
    }

    @Test func deviceMiningSnapshotIsNilWithoutMiningBlock() {
        #expect(makeDevice(detail: .object([:])).miningSnapshot == nil)
    }

    private func makeDevice(detail: JSONValue) -> Device {
        Device(
            deviceCode: "32658E70", deviceType: "mining_drone", replicantCode: "R1",
            status: "mining (structural)", location: "ATIANFU-BELT-1", locationName: nil,
            operationalCapacity: 97, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [],
            tags: [], detail: detail, updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
