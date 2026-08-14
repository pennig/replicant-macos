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
            EventRunFixtures.device("COURIER", type: "matrix_container", location: "X-1"),
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
            nextStep: EventRun.Step.recovering
        ))
    }

    @Test("a beacon left on site is never recovered")
    func leavesBeacon() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
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
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
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

    @Test("both hulls home finishes the run")
    func finishes() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.returning, now: now), world: world
        )
        #expect(action == .done)
    }

    @Test("EventRun is registered")
    func registered() {
        #expect(MissionRegistry.machine(for: .eventRun) != nil)
        #expect(MissionRegistry.firstStep(for: .eventRun) == EventRun.Step.preflight)
    }
}
