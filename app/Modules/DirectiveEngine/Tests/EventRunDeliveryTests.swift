//
//  EventRunDeliveryTests.swift
//  Replicould — DirectiveEngine
//
//  `EventRun`'s delivery legs as a verdict table: departure, arrival, staging.
//

import Foundation
import GameModels
import GameServices
import Testing
@testable import DirectiveEngine

@Suite("EventRun — delivery")
struct EventRunDeliveryTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("departing flies both hulls to the event location")
    func departs() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.departing, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "CARRIER",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.departing
        ))
    }

    @Test("with the carrier away, departing moves the freighter next")
    func freighterFollows() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.departing, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "FREIGHT",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.confirmingArrival
        ))
    }

    @Test("arrival needs rows read since the step began")
    func arrivalNeedsFreshRows() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingArrival, now: now), world: world
        )
        // Rows predate the step, so the machine buys evidence rather than trusting them.
        #expect(action != .advanceStep(nextStep: EventRun.Step.staging))
    }

    @Test("both hulls confirmed on site advances to staging")
    func arrivalConfirmed() {
        let fresh = now.addingTimeInterval(1)
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1", updatedAt: fresh),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1", updatedAt: fresh),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1", updatedAt: fresh),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: fresh
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingArrival, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.staging))
    }

    @Test("staging detaches the whole load in one command, courier excluded")
    func stagingDetaches() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("GRID", type: "defence_grid", attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: [(1, "defence_grid")]), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.staging, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .detach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["BEACON", "GRID"]),
            nextStep: EventRun.Step.confirmingStage
        ))
    }

    @Test("with the load down, staging deposits the freighter's hold")
    func stagingDeposits() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.staging, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .depositResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["structural": 200]),
            nextStep: EventRun.Step.confirmingStage
        ))
    }

    // MARK: - Bounds

    /// The staging convoy with its whole load still reading as aboard.
    private func unreflectedLoad() -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER", location: "X-1"),
        ]
    }

    private func stagingLog(_ kinds: [OperationKind]) -> [DirectiveLogEntry] {
        var log = [EventRunFixtures.entered(EventRun.Step.staging, at: now)]
        for (index, kind) in kinds.enumerated() {
            log.append(EventRunFixtures.dispatched(
                kind, to: "CARRIER", step: EventRun.Step.confirmingStage,
                at: now.addingTimeInterval(Double(index) + 1)
            ))
            log.append(EventRunFixtures.entered(
                EventRun.Step.confirmingStage, at: now.addingTimeInterval(Double(index) + 2)
            ))
            log.append(EventRunFixtures.entered(
                EventRun.Step.staging, at: now.addingTimeInterval(Double(index) + 3)
            ))
        }
        return log
    }

    @Test("a detach that never reflects is not re-ordered")
    func detachIsOrderedOnce() {
        let world = EventRunFixtures.world(
            devices: unreflectedLoad(),
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now,
            log: stagingLog([.detach])
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.staging, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .depositResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["structural": 200]),
            nextStep: EventRun.Step.confirmingStage
        ))
    }

    @Test("with both legs ordered, staging leaves for the event's own progress")
    func stagingTerminates() {
        let world = EventRunFixtures.world(
            devices: unreflectedLoad(),
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now,
            log: stagingLog([.detach, .depositResources])
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.staging, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.confirmingProgress))
    }

    @Test("a detach still unreflected at the deadline stalls rather than looping")
    func confirmStageStalls() {
        let expired = now.addingTimeInterval(EventRun.stageConfirmDeadline + 1)
        let world = EventRunFixtures.world(
            devices: unreflectedLoad(),
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: expired,
            log: stagingLog([.detach])
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingStage, now: now),
            world: world
        )
        #expect(action == .refreshDevices(deviceCodes: ["BEACON"], thenStall: .commandRejected))
    }

    @Test("a deposit is handed back rather than judged on the hold")
    func confirmStageHandsADepositBack() {
        let world = EventRunFixtures.world(
            devices: unreflectedLoad(),
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now,
            log: stagingLog([.detach, .depositResources])
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingStage, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.staging))
    }

    private func loadingLog(at start: Date) -> [DirectiveLogEntry] {
        [
            EventRunFixtures.entered(EventRun.Step.loading, at: start),
            EventRunFixtures.dispatched(
                .attach, to: "CARRIER", step: EventRun.Step.confirmingLoad,
                at: start.addingTimeInterval(1)
            ),
            EventRunFixtures.entered(EventRun.Step.confirmingLoad, at: start.addingTimeInterval(2)),
        ]
    }

    @Test("an attach that never reflects holds the confirm rather than re-entering loading")
    func confirmLoadHolds() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now,
            log: loadingLog(at: now)
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingLoad, now: now),
            world: world
        )
        #expect(action != .advanceStep(nextStep: EventRun.Step.loading))
        #expect(action == .refreshDevices(deviceCodes: ["COURIER"], thenStall: nil))
    }

    @Test("an attach still unreflected at the deadline stalls the load loop")
    func confirmLoadStalls() {
        let expired = now.addingTimeInterval(EventRun.loadConfirmDeadline + 1)
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: expired,
            log: loadingLog(at: now)
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingLoad, now: now),
            world: world
        )
        #expect(action == .refreshDevices(deviceCodes: ["COURIER"], thenStall: .commandRejected))
    }

    @Test("an attach that landed lets the load loop take the next member")
    func confirmLoadAdvances() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now,
            log: loadingLog(at: now)
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingLoad, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading))
    }
}
