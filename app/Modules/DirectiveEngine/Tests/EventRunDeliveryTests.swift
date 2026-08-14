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
}
