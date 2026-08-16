import Foundation
import GameModels
import GameServices
import Testing
@testable import DirectiveEngine

@Suite("EventRun — recovery and return")
struct EventRunReturnTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("recovering re-attaches a detached courier before departing")
    func reattachesCourier() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.courier(location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.recovering, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .attach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["COURIER"]),
            nextStep: EventRun.Step.confirmingRecovery
        ))
    }

    @Test("a courier still loose buys evidence rather than departing")
    func looseCourierNeverDeparts() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.courier(location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingRecovery, now: now),
            world: world
        )
        #expect(action == .refreshDevices(deviceCodes: ["COURIER"], thenStall: nil))
    }

    @Test("a courier that will not attach stalls instead of looping")
    func unattachableCourierStalls() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.courier(location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let entered = now.addingTimeInterval(-EventRun.recoveryConfirmDeadline - 1)
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingRecovery, now: entered),
            world: world
        )
        #expect(action == .refreshDevices(deviceCodes: ["COURIER"], thenStall: .commandRejected))
    }

    @Test("a courier read as aboard hands back to recovering")
    func confirmedCourierHandsBack() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.courier(attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingRecovery, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.recovering))
    }

    @Test("a beacon left on site is never recovered")
    func leavesBeacon() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.courier(attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.recovering, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.returning))
    }

    @Test("returning flies both hulls to the theatre depot")
    func returnsHome() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.courier(attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.returning, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "CARRIER",
            params: CommandParams(destination: "HUB-1"),
            nextStep: EventRun.Step.returning
        ))
    }

    @Test("both hulls home hands the hold to the depositing step")
    func finishes() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(attachedTo: "CARRIER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.returning, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.depositing))
    }

    /// The convoy home at the depot, the reward still in the freighter's hold.
    private func homeConvoy(cargoUsed: Int) -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device(
                "FREIGHT", type: "cargo_freighter", cargoUsed: cargoUsed, cargoCapacity: 500
            ),
            EventRunFixtures.courier(attachedTo: "CARRIER"),
        ]
    }

    @Test("a loaded hold is emptied at the depot rather than parked full")
    func depositsTheReward() {
        // The executor has already stamped this step's own entry by the time the
        // machine is asked, which is what any dispatch budget here must survive.
        let world = EventRunFixtures.world(
            devices: homeConvoy(cargoUsed: 350),
            event: EventRunFixtures.event(resources: [:], devices: []), now: now,
            log: [
                EventRunFixtures.entered(EventRun.Step.returning, at: now.addingTimeInterval(-60)),
                EventRunFixtures.entered(EventRun.Step.depositing, at: now),
            ]
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.depositing, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .depositResources, deviceCode: "FREIGHT",
            params: CommandParams(), nextStep: EventRun.Step.confirmingDeposit
        ))
    }

    @Test("an empty hold finishes the run")
    func emptyHoldFinishes() {
        let world = EventRunFixtures.world(
            devices: homeConvoy(cargoUsed: 0),
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.depositing, now: now), world: world
        )
        #expect(action == .done)
    }

    @Test("the unload is ordered once per visit, never re-sent")
    func depositsOnlyOnce() {
        let entered = now.addingTimeInterval(-30)
        let world = EventRunFixtures.world(
            devices: homeConvoy(cargoUsed: 350),
            event: EventRunFixtures.event(resources: [:], devices: []), now: now,
            log: [
                EventRunFixtures.entered(EventRun.Step.depositing, at: entered),
                EventRunFixtures.dispatched(
                    .depositResources, to: "FREIGHT",
                    step: EventRun.Step.confirmingDeposit, at: entered
                ),
                EventRunFixtures.entered(EventRun.Step.confirmingDeposit, at: entered),
                EventRunFixtures.entered(EventRun.Step.depositing, at: now),
            ]
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.depositing, now: now), world: world
        )
        #expect(action == .done)
    }

    @Test("a hold read as emptied hands back and finishes")
    func confirmedDepositHandsBack() {
        var freight = EventRunFixtures.device(
            "FREIGHT", type: "cargo_freighter", cargoUsed: 0, cargoCapacity: 500
        )
        freight.updatedAt = now
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            freight,
            EventRunFixtures.courier(attachedTo: "CARRIER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingDeposit, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.depositing))
    }

    @Test("a hold that will not empty stalls instead of looping")
    func unemptiableHoldStalls() {
        let world = EventRunFixtures.world(
            devices: homeConvoy(cargoUsed: 350),
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let entered = now.addingTimeInterval(-EventRun.depositConfirmDeadline - 1)
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingDeposit, now: entered),
            world: world
        )
        #expect(action == .refreshDevices(deviceCodes: ["FREIGHT"], thenStall: .commandRejected))
    }

    @Test("EventRun is registered")
    func registered() {
        #expect(MissionRegistry.machine(for: .eventRun) != nil)
        #expect(MissionRegistry.firstStep(for: .eventRun) == EventRun.Step.preflight)
    }
}
