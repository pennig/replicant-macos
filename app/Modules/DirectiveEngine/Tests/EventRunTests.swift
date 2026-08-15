//
//  EventRunTests.swift
//  Replicould — DirectiveEngine
//
//  `EventRun` as a verdict table: preflight, the prints, and the load.
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

    @Test("preflight refuses to start a run the reserve rail would veto")
    func preflightHonoursTheRail() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: now, stock: 1
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.preflight, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("preflight buys a census read before trusting the rail")
    func preflightRefreshesAStaleCensus() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: now, footprintFresh: false
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.preflight, now: now), world: world
        )
        #expect(action == .refreshFootprint(nextStep: EventRun.Step.preflight, thenStall: nil))
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

/// The option whose device is itself printed out of other printed devices: one
/// `atmospheric_regulator` over a `filtration_array` and two `atmo_processor`s.
@Suite("EventRun — component prints")
struct EventRunComponentPrintTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let tag = EventRun.fleetTag(forTheatre: "HUB-1")
    private let bills: [String: ResourceCost] = [
        "atmospheric_regulator": ResourceCost(structural: 200),
        "filtration_array": ResourceCost(structural: 140),
        "atmo_processor": ResourceCost(structural: 200),
        "ftl_beacon": ResourceCost(structural: 50),
    ]
    private let components = [
        "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2]
    ]

    /// A depot printer reading fresher than the step, or `printing` buys a
    /// device read before it dispatches anything.
    private func factory(_ code: String = "FACTORY") -> Device {
        EventRunFixtures.device(code, type: "autofactory", updatedAt: now)
    }

    /// `FACTORY`, reporting the shortfall a queued job is parked on.
    private func blockedFactory(_ shortfall: [String: (Int, Int)]) -> Device {
        var device = factory()
        device.detail = .object([
            "waiting_for": .object([
                "components": .object(shortfall.mapValues {
                    .object(["have": .number(Double($0.0)), "need": .number(Double($0.1))])
                })
            ])
        ])
        return device
    }

    private func world(
        _ extraDevices: [Device], busy: [String] = [], stepStartedAt: Date
    ) -> WorldSnapshot {
        var openOperations: [String: GameModels.Operation] = [:]
        for code in busy {
            openOperations.merge(EventRunFixtures.openPrint(on: code, now: stepStartedAt)) {
                _, latest in latest
            }
        }
        return EventRunFixtures.world(
            devices: [
                EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
                EventRunFixtures.courier(),
            ] + extraDevices,
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            now: now,
            openOperations: openOperations,
            blueprintBills: bills,
            blueprintComponents: components
        )
    }

    @Test("printing dispatches a component before the device that consumes it")
    func componentsPrintFirst() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now),
            world: world([factory()], stepStartedAt: now)
        )
        guard case .dispatch(_, _, let params, _) = action else {
            Issue.record("expected a dispatch, got \(action)"); return
        }
        #expect(params.deviceType == "atmo_processor")
        #expect(params.quantity == 2)
    }

    @Test("a component already standing under the run's tag is not reprinted")
    func standingComponentIsNetted() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now),
            world: world(
                [
                    factory(),
                    EventRunFixtures.device("AP1", type: "atmo_processor", tags: [tag]),
                    EventRunFixtures.device("AP2", type: "atmo_processor", tags: [tag]),
                ],
                stepStartedAt: now
            )
        )
        guard case .dispatch(_, _, let params, _) = action else {
            Issue.record("expected a dispatch, got \(action)"); return
        }
        #expect(params.deviceType == "filtration_array")
    }

    @Test("an untagged component of the standing fleet is never scavenged")
    func untaggedComponentIsNotNetted() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now),
            world: world(
                [
                    factory(),
                    EventRunFixtures.device("AP1", type: "atmo_processor", tags: []),
                    EventRunFixtures.device("AP2", type: "atmo_processor", tags: []),
                ],
                stepStartedAt: now
            )
        )
        guard case .dispatch(_, _, let params, _) = action else {
            Issue.record("expected a dispatch, got \(action)"); return
        }
        #expect(params.deviceType == "atmo_processor")
        #expect(params.quantity == 2)
    }

    @Test("a printer with nothing queued takes the job the blocked one cannot")
    func aFreePrinterTakesTheComponentJob() {
        let started = now.addingTimeInterval(-EventRun.printDeadline - 60)
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: started),
            world: world(
                [blockedFactory(["atmo_processor": (0, 2)]), factory("SPARE")],
                busy: ["FACTORY"], stepStartedAt: started
            )
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "SPARE",
            params: CommandParams(deviceType: "atmo_processor", quantity: 2, printTags: [tag]),
            nextStep: EventRun.Step.printing
        ))
    }

    @Test("a print blocked past the deadline stalls instead of waiting forever")
    func blockedPrintStalls() {
        let started = now.addingTimeInterval(-EventRun.printDeadline - 60)
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: started),
            world: world(
                [blockedFactory(["atmo_processor": (0, 2)])],
                busy: ["FACTORY"], stepStartedAt: started
            )
        )
        guard case .stall(let reason, _) = action else {
            Issue.record("expected a stall, got \(action)"); return
        }
        #expect(reason == .printBlockedOnComponents)
    }

    @Test("a print blocked inside the deadline waits")
    func blockedPrintWaitsInsideTheDeadline() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now),
            world: world(
                [blockedFactory(["atmo_processor": (0, 2)])],
                busy: ["FACTORY"], stepStartedAt: now
            )
        )
        #expect(action == .wait)
    }

    @Test("the server's own shortfall outranks the local expansion")
    func serverShortfallLeadsTheOrder() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing, now: now),
            world: world(
                [blockedFactory(["coolant_loop": (1, 3)]), factory("SPARE")],
                busy: ["FACTORY"], stepStartedAt: now
            )
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "SPARE",
            params: CommandParams(deviceType: "coolant_loop", quantity: 2, printTags: [tag]),
            nextStep: EventRun.Step.printing
        ))
    }
}
