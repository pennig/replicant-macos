//
//  StowOrAttachTests.swift
//  Replicould — DirectiveEngine
//
//  Containment orders: which device goes next, which column proves it landed,
//  and how many devices ride one command.
//

import Foundation
import GameModels
import GameServices
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)

private func device(
    _ code: String, attachedTo: String? = nil, controlledBy: String? = nil
) -> Device {
    Device(
        deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: "idle",
        location: "AINALRAM-BELT-1", locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: controlledBy, attachedToDeviceCode: attachedTo,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object([:]),
        updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func row() -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: "C1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["AINALRAM-BELT-1"], targetIndex: 0, step: "attaching",
        stepStartedAt: now.addingTimeInterval(-60), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: now, theatreDepot: nil
    )
}

private func ctx(_ devices: [Device]) -> StepContext {
    StepContext(
        directive: row(),
        world: WorldSnapshot(
            devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
            openOperations: [:], now: now
        ),
        step: "attaching"
    )
}

@Suite("Stow or attach")
struct StowOrAttachTests {
    private func attachJob(_ codes: [String]) -> StowOrAttach {
        StowOrAttach(
            carrierCode: "C1", deviceCodes: codes, verb: .attach,
            confirmField: .attachedTo, confirmStep: "confirmingAttach", sendsWholeList: false
        )
    }

    private func adoptJob(_ codes: [String], sendsWholeList: Bool) -> StowOrAttach {
        StowOrAttach(
            carrierCode: "A1", deviceCodes: codes, verb: .adopt,
            confirmField: .controlledBy, confirmStep: "confirmingAdopt",
            sendsWholeList: sendsWholeList
        )
    }

    /// The caller's order is the dispatch order. `EventRun.loading` prepends the
    /// courier ahead of a code-sorted payload, so re-sorting here would move it.
    @Test("attach orders the first pending device in the order given")
    func attachOrdersTheFirstPendingInTheOrderGiven() {
        let job = attachJob(["D9", "D1"])
        #expect(job.next(ctx([device("D9"), device("D1")])) == .action(.dispatch(
            kind: .attach, deviceCode: "C1",
            params: CommandParams(devices: ["D9"]), nextStep: "confirmingAttach"
        )))
    }

    @Test("attach passes over the devices already aboard")
    func attachPassesOverThoseAboard() {
        let job = attachJob(["D9", "D1"])
        let world = ctx([device("D9", attachedTo: "C1"), device("D1")])
        #expect(job.next(world) == .action(.dispatch(
            kind: .attach, deviceCode: "C1",
            params: CommandParams(devices: ["D1"]), nextStep: "confirmingAttach"
        )))
    }

    @Test("attach finishes once every device is aboard")
    func attachFinishesWhenAllAboard() {
        let job = attachJob(["D9", "D1"])
        #expect(job.next(ctx([device("D9", attachedTo: "C1"), device("D1", attachedTo: "C1")])) == .finished)
    }

    /// `adopt` proves itself on `controllerDeviceCode`; a row merely attached to
    /// the controller is not adopted.
    @Test("adopt confirms on the controller column, not the attach column")
    func adoptConfirmsOnTheControllerColumn() {
        let job = adoptJob(["D1"], sendsWholeList: true)
        #expect(job.next(ctx([device("D1", controlledBy: "A1")])) == .finished)
        #expect(job.next(ctx([device("D1", attachedTo: "A1")])) == .action(.dispatch(
            kind: .adopt, deviceCode: "A1",
            params: CommandParams(devices: ["D1"]), nextStep: "confirmingAdopt"
        )))
    }

    /// Batch-ness is a property of the site, not of the verb: `adopt` hands a
    /// controller its whole list, while `attach` moves one row at a time.
    @Test("a whole-list job sends every pending device in one command")
    func wholeListSendsEveryPendingDevice() {
        let job = adoptJob(["D1", "D2", "D3"], sendsWholeList: true)
        #expect(job.next(ctx([device("D1"), device("D2"), device("D3")])) == .action(.dispatch(
            kind: .adopt, deviceCode: "A1",
            params: CommandParams(devices: ["D1", "D2", "D3"]), nextStep: "confirmingAdopt"
        )))
    }

    @Test("a one-per-round job sends one device from the same list")
    func onePerRoundSendsOneDevice() {
        let job = adoptJob(["D1", "D2", "D3"], sendsWholeList: false)
        #expect(job.next(ctx([device("D1"), device("D2"), device("D3")])) == .action(.dispatch(
            kind: .adopt, deviceCode: "A1",
            params: CommandParams(devices: ["D1"]), nextStep: "confirmingAdopt"
        )))
    }

    @Test("a whole-list job sends only the devices still pending")
    func wholeListSendsOnlyPending() {
        let job = adoptJob(["D1", "D2", "D3"], sendsWholeList: true)
        let world = ctx([device("D1", controlledBy: "A1"), device("D2"), device("D3")])
        #expect(job.next(world) == .action(.dispatch(
            kind: .adopt, deviceCode: "A1",
            params: CommandParams(devices: ["D2", "D3"]), nextStep: "confirmingAdopt"
        )))
    }

    /// A named device the world holds no row for is the mission's call, never a
    /// stall from here.
    @Test("a named device with no row is no subject")
    func aNamedDeviceWithNoRowIsNoSubject() {
        #expect(attachJob(["D9", "D1"]).next(ctx([device("D9")])) == .noSubject)
    }

    /// `.loose` is the one field that is NOT carrier-scoped: it asks only whether
    /// the column is empty, so a device on someone else's grid still reads as
    /// pending. Both shipped sites pre-filter to their own carrier.
    @Test("detach counts a device on a foreign carrier as pending")
    func detachCountsAForeignCarrierAsPending() {
        let job = StowOrAttach(
            carrierCode: "C1", deviceCodes: ["D1"], verb: .detach,
            confirmField: .loose, confirmStep: "confirmingDetach", sendsWholeList: true
        )
        #expect(job.next(ctx([device("D1", attachedTo: "C2")])) == .action(.dispatch(
            kind: .detach, deviceCode: "C1",
            params: CommandParams(devices: ["D1"]), nextStep: "confirmingDetach"
        )))
    }

    /// Detach's proof is the empty column, so an already-loose device is placed
    /// and only the attached ones ride the command.
    @Test("detach counts a loose device as placed")
    func detachCountsALooseDeviceAsPlaced() {
        let job = StowOrAttach(
            carrierCode: "C1", deviceCodes: ["D1", "D2"], verb: .detach,
            confirmField: .loose, confirmStep: "confirmingDetach", sendsWholeList: true
        )
        #expect(job.next(ctx([device("D1"), device("D2")])) == .finished)
        let world = ctx([device("D1"), device("D2", attachedTo: "C1")])
        #expect(job.next(world) == .action(.dispatch(
            kind: .detach, deviceCode: "C1",
            params: CommandParams(devices: ["D2"]), nextStep: "confirmingDetach"
        )))
    }
}
