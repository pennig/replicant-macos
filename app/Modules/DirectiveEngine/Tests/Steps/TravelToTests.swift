//
//  TravelToTests.swift
//  Replicould — DirectiveEngine
//
//  The travel frame: guard order, both arrival tests, and the same-step loop.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)

private func row(step: String = "travelling", startedAgo: TimeInterval = 30) -> Directive {
    Directive(
        id: "D1", kind: .salvageRun, status: .running, deviceCode: "V1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["SOL"], targetIndex: 0, step: step,
        stepStartedAt: now.addingTimeInterval(-startedAgo),
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: now.addingTimeInterval(-3_600), updatedAt: now, theatreDepot: nil
    )
}

private func vessel(at location: String?, updatedAt: Date = now) -> Device {
    Device(
        deviceCode: "V1", deviceType: "heaven_vessel", replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func travelOp(status: OperationStatus, confirmedAt: Date) -> GameModels.Operation {
    GameModels.Operation(
        id: "OP1", entityCode: "V1", kind: OperationKind.travel.rawValue, status: status, source: .optimistic,
        startedAt: confirmedAt.addingTimeInterval(-600), completesAt: confirmedAt,
        lastConfirmedAt: confirmedAt, detail: .object([:]),
        directiveID: "D1", step: "travelling", paramsDigest: nil
    )
}

private func ctx(
    _ device: Device, open: [String: GameModels.Operation] = [:],
    dispatched: [String: GameModels.Operation] = [:], startedAgo: TimeInterval = 30
) -> StepContext {
    StepContext(
        directive: row(startedAgo: startedAgo),
        world: WorldSnapshot(
            devices: ["V1": device], openOperations: open,
            dispatchedOperations: dispatched, now: now
        ),
        step: "travelling"
    )
}

@Suite("Travel to")
struct TravelToTests {
    private let toSystem = TravelTo(
        deviceCode: "V1", destination: "SOL", arrivalTest: .system, confirmStep: nil
    )

    /// The two arrival roots. Every reader — five mission test sites and
    /// `SalvageRun`'s recall ladder — writes its fixture RELATIVE to these, so
    /// without this nothing in the engine notices either value change.
    @Test("the arrival bounds are the roots the missions were repointed onto")
    func theArrivalBoundsAreTheRoots() {
        #expect(TravelTo.arrivalConfirmDeadline == 5 * 60)
        #expect(TravelTo.arrivalReadInterval == 30)
    }

    /// A location is a SITE, not a system: `SOL-3` is in `SOL`.
    @Test("the system test accepts any site in the destination system")
    func systemTestAcceptsASiteInTheSystem() {
        #expect(toSystem.next(ctx(vessel(at: "SOL-3"))) == .finished)
    }

    @Test("the exact test rejects a sibling site in the same system")
    func exactTestRejectsASiblingSite() {
        let exact = TravelTo(
            deviceCode: "V1", destination: "SOL-3-1", arrivalTest: .exactLocation, confirmStep: nil
        )
        #expect(exact.next(ctx(vessel(at: "SOL-3"))) != .finished)
    }

    /// 11 of the 13 sites loop on their own step; a tracked `.travel` op is
    /// what stops the dispatch re-issuing every tick.
    @Test("a nil confirm step dispatches into the mission's own step")
    func nilConfirmStepLoopsOnItsOwnStep() {
        #expect(toSystem.next(ctx(vessel(at: "VEGA-1"))) == .action(.dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: "SOL"), nextStep: "travelling"
        )))
    }

    @Test("a named confirm step dispatches into it instead")
    func namedConfirmStepIsUsed() {
        let paired = TravelTo(
            deviceCode: "V1", destination: "SOL", arrivalTest: .system,
            confirmStep: "confirmingArrival"
        )
        #expect(paired.next(ctx(vessel(at: "VEGA-1"))) == .action(.dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: "SOL"), nextStep: "confirmingArrival"
        )))
    }

    @Test("an in-flight op waits rather than commanding a second travel")
    func anOpenOpWaits() {
        let open = ["V1": travelOp(status: .active, confirmedAt: now)]
        #expect(toSystem.next(ctx(vessel(at: "VEGA-1"), open: open)) == .action(.wait))
    }

    /// One arrival settles in two transactions — the op closes, then the
    /// location is written. A tick in that gap must not re-command travel.
    @Test("a row predating its own arrival buys a read instead of dispatching")
    func aRowPredatingItsArrivalBuysARead() {
        let arrival = now.addingTimeInterval(-60)
        let stale = vessel(at: "VEGA-1", updatedAt: arrival.addingTimeInterval(-120))
        let result = toSystem.next(ctx(
            stale, dispatched: ["OP1": travelOp(status: .completed, confirmedAt: arrival)]
        ))
        #expect(result == .action(.refreshDevices(deviceCodes: ["V1"], thenStall: nil)))
    }

    /// Deadline BEFORE the read: a failing read never advances `updatedAt`.
    @Test("past the deadline the read carries a stall")
    func pastTheDeadlineTheReadStalls() {
        let arrival = now.addingTimeInterval(-(TravelTo.arrivalConfirmDeadline + 1))
        let stale = vessel(at: "VEGA-1", updatedAt: arrival.addingTimeInterval(-120))
        let result = toSystem.next(ctx(
            stale, dispatched: ["OP1": travelOp(status: .completed, confirmedAt: arrival)]
        ))
        #expect(result == .action(.refreshDevices(
            deviceCodes: ["V1"], thenStall: .vesselPositionUnconfirmed
        )))
    }

    /// `.superseded` and `.unknown` also stamp `lastConfirmedAt` on travels
    /// that never arrived; gating on one blocks a real dispatch forever.
    @Test("only a completed travel is a watermark")
    func onlyACompletedTravelIsAWatermark() {
        let arrival = now.addingTimeInterval(-60)
        let stale = vessel(at: "VEGA-1", updatedAt: arrival.addingTimeInterval(-120))
        let result = toSystem.next(ctx(
            stale, dispatched: ["OP1": travelOp(status: .superseded, confirmedAt: arrival)]
        ))
        #expect(result == .action(.dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: "SOL"), nextStep: "travelling"
        )))
    }

    @Test("an unknown device is no subject, not a stall")
    func anUnknownDeviceIsNoSubject() {
        let empty = StepContext(
            directive: row(),
            world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
            step: "travelling"
        )
        #expect(toSystem.next(empty) == .noSubject)
    }
}
