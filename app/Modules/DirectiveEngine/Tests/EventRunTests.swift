//
//  EventRunTests.swift
//  Replicould — DirectiveEngine
//
//  `EventRun` as a verdict table: preflight, the beacon print, and the load.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

@Suite("EventRun — loading")
struct EventRunLoadingTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("preflight prints the beacon when the location has none")
    func printsBeacon() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.preflight, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.printing))
    }

    @Test("printing enqueues the beacon at the depot printer")
    func enqueuesBeacon() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: "ftl_beacon", quantity: 1,
                printTags: [EventRun.fleetTag(forTheatre: "HUB-1")]
            ),
            nextStep: EventRun.Step.printing
        ))
    }

    @Test("a beacon already standing at the event location is not reprinted")
    func skipsExistingBeacon() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
            EventRunFixtures.device("OLDBEACON", type: "ftl_beacon", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading))
    }

    @Test("the reserve rail vetoes a print rather than spending")
    func railVetoes() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: now, stock: 1
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("loading attaches the courier first, one attach per round")
    func attachesCourier() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .attach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["COURIER"]),
            nextStep: EventRun.Step.confirmingLoad
        ))
    }

    @Test("with everything attached, loading fills the freighter and departs")
    func collectsResources() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(attachedTo: "CARRIER"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["structural": 200]),
            nextStep: EventRun.Step.confirmingLoad
        ))
    }

    @Test("a missing courier idles rather than stalling")
    func noCourierWaits() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }

    @Test("a device roster older than the step buys one authoritative read first")
    func staleFleetEvidenceReadsBeforePrinting() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory"),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .refreshDevicesInSystem(
            designation: "HUB-1", thenStall: .unreachableDevice
        ))
    }

    @Test("a tagged beacon already waiting at the depot is not printed again")
    func skipsBeaconStandingAtTheDepot() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
            EventRunFixtures.device("BEACON", type: "ftl_beacon",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading))
    }

    @Test("a print already in flight at the printer is not doubled")
    func waitsOnAnOpenPrint() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: now, openOperations: EventRunFixtures.openPrint(on: "PRINTER", now: now)
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("a missing freighter re-reads the fleet rather than stalling")
    func noFreighterRereadsTheFleet() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.courier(),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }

    @Test("a hold already carrying something departs rather than collecting twice")
    func partiallyLoadedHoldDeparts() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", cargoUsed: 120),
            EventRunFixtures.courier(attachedTo: "CARRIER"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.departing))
    }

    /// The two containers a depot really holds: one hosting another
    /// automation's replicant and never printed by this capability, and one
    /// this capability printed that nobody has replicated into yet.
    private func mixedContainers() -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("ANCHOR", type: "matrix_container"),
            EventRunFixtures.courier("PRINTED"),
        ]
    }

    @Test("neither an untagged host nor an unreplicated print is a courier")
    func ignoresTheAnchorHostAndTheUnreplicatedPrint() {
        let world = EventRunFixtures.world(
            devices: mixedContainers(),
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: now, hosts: ["ANCHOR"]
        )
        let directive = EventRunFixtures.directive(step: EventRun.Step.loading, now: now)
        #expect(EventRun.convoy(of: directive, in: world)?.courier == nil)
        #expect(EventRun().nextAction(directive: directive, world: world) == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }

    @Test("a tagged container with a replicant in it IS the courier")
    func selectsTheOwnedHostedContainer() {
        let world = EventRunFixtures.world(
            devices: mixedContainers(),
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: now, hosts: ["ANCHOR", "PRINTED"]
        )
        let directive = EventRunFixtures.directive(step: EventRun.Step.loading, now: now)
        #expect(EventRun.convoy(of: directive, in: world)?.courier?.deviceCode == "PRINTED")
        #expect(EventRun().nextAction(directive: directive, world: world) == .dispatch(
            kind: .attach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["PRINTED"]),
            nextStep: EventRun.Step.confirmingLoad
        ))
    }

    @Test("a container attached to another carrier is not this run's courier")
    func ignoresACourierAboardAnotherCarrier() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("OTHER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.courier(attachedTo: "OTHER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }
}
