//
//  ConfirmRowTests.swift
//  Replicould — DirectiveEngine
//
//  The ordering rule, tested once: deadline before read, always.
//

import Foundation
import GameModels
import Testing
import Utils

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)

private func row(startedAgo: TimeInterval) -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: "C1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["SOL"], targetIndex: 0, step: "confirming",
        stepStartedAt: now.addingTimeInterval(-startedAgo), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: now.addingTimeInterval(-3_600), updatedAt: now, theatreDepot: nil
    )
}

private func device(_ code: String, updatedAt: Date, arrival: Date? = nil) -> Device {
    var detail: [String: JSONValue] = [:]
    if let arrival {
        detail["travel"] = .object(["arrives_at": .string(arrival.formatted(.iso8601))])
    }
    return Device(
        deviceCode: code, deviceType: "service_bot", replicantCode: "R1", status: "idle",
        location: "SOL-3", locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object(detail),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func ctx(_ startedAgo: TimeInterval) -> StepContext {
    StepContext(
        directive: row(startedAgo: startedAgo),
        world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
        step: "confirming"
    )
}

@Suite("Confirm row")
struct ConfirmRowTests {
    private let ladder = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))

    /// THE rule this whole sub-machine exists to hold. A failing read never
    /// advances `updatedAt`, so a staleness-first order can never reach the
    /// deadline and loops at one high-priority read per tick forever.
    @Test("the deadline is read before the staleness gate")
    func theDeadlineComesFirst() {
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(ladder.verdict([stale], ctx(301)) == .act(.refreshDevices(
            deviceCodes: ["B1"], thenStall: .commandRejected
        )))
    }

    @Test("fresh rows are handed back for the mission to judge")
    func freshRowsAreJudged() {
        #expect(ladder.verdict([device("B1", updatedAt: now)], ctx(60)) == .judge)
    }

    @Test("a stale row inside the deadline buys a throttled read")
    func aStaleRowBuysAThrottledRead() {
        let stale = device("B1", updatedAt: now.addingTimeInterval(-60))
        #expect(ladder.verdict([stale], ctx(0)) == .act(.refreshDevices(
            deviceCodes: ["B1"], thenStall: nil
        )))
    }

    @Test("a row read within the interval waits rather than reading again")
    func aRecentlyReadRowWaits() {
        let stale = device("B1", updatedAt: now.addingTimeInterval(-5))
        #expect(ladder.verdict([stale], ctx(0)) == .act(.wait))
    }

    /// The non-stall exit: four bot sites proceed unrepaired rather than halt.
    @Test("expiry can hand back instead of stalling")
    func expiryCanHandBack() {
        let judgeOnExpiry = ConfirmRow(deadline: 300, onExpiry: .judge)
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(judgeOnExpiry.verdict([stale], ctx(301)) == .judge)
    }

    /// `awaitRepair` and `confirmRelay` stall outright rather than paying for
    /// one more read they have no reason to believe will answer.
    @Test("expiry can stall outright without buying a read")
    func expiryCanStallOutright() {
        let stallNow = ConfirmRow(deadline: 300, onExpiry: .stallNow(.repairUnfinished))
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(stallNow.verdict([stale], ctx(301)) == .act(.stall(.repairUnfinished)))
    }

    /// A recalled device carries `location: nil` and cruises home; a read
    /// before its own arrival buys nothing at all.
    @Test("waiting out an arrival beats reading a device still in flight")
    func waitingOutAnArrival() {
        var waits = ConfirmRow(deadline: 1_200, onExpiry: .stallNow(.serviceBotNotRecovered))
        waits.waitsOutArrival = true
        let cruising = device(
            "B1", updatedAt: now.addingTimeInterval(-10_000),
            arrival: now.addingTimeInterval(120)
        )
        #expect(waits.verdict([cruising], ctx(60)) == .act(.wait))
    }

    /// One arrival event and a sub-second local clock can disagree by seconds.
    @Test("a skewed watermark accepts a row a few seconds early")
    func aSkewedWatermarkAcceptsAnEarlyRow() {
        var skewed = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))
        skewed.watermark = .skewed(5)
        let justBefore = device("B1", updatedAt: now.addingTimeInterval(-63))
        #expect(skewed.verdict([justBefore], ctx(60)) == .judge)
    }

    /// The drones may be anywhere, so they are not addressable by code.
    @Test("a fleet refresh replaces the device refresh wholesale")
    func aFleetRefreshIsUsedWhenAsked() {
        let tag = FleetTag(goal: .salvage)
        var fleet = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))
        fleet.refresh = .fleet(tag)
        let stale = device("B1", updatedAt: now.addingTimeInterval(-60))
        #expect(fleet.verdict([stale], ctx(0)) == .act(.refreshFleet(tag: tag, thenStall: nil)))
    }

    @Test("inside the probe delay nothing is read at all")
    func insideTheProbeDelayNothingIsRead() {
        var delayed = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))
        delayed.probeDelay = 10
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(delayed.verdict([stale], ctx(5)) == .act(.wait))
    }
}
