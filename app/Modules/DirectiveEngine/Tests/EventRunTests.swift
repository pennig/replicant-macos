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
            directive: EventRunFixtures.directive(step: EventRun.Step.preflight.rawValue, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.printing.rawValue))
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
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: "ftl_beacon", quantity: 1,
                printTags: [EventRun.fleetTag(forTheatre: "HUB-1").string]
            ),
            nextStep: EventRun.Step.printing.rawValue
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
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading.rawValue))
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
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("loading attaches the courier first, one attach per round")
    func attachesCourier() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", tags: [EventRun.fleetTag(forTheatre: "HUB-1").string]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .attach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["COURIER"]),
            nextStep: EventRun.Step.confirmingLoad.rawValue
        ))
    }

    @Test("with everything attached, loading fills the freighter and departs")
    func collectsResources() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.courier(attachedTo: "CARRIER"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1").string]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .collectResources, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["structural": 200]),
            nextStep: EventRun.Step.confirmingLoad.rawValue
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
            directive: EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now), world: world
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
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now), world: world
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
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1").string]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading.rawValue))
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
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("a missing freighter re-reads the fleet rather than stalling")
    func noFreighterRereadsTheFleet() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.courier(),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1").string]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now), world: world
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
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1").string]),
        ]
        let world = EventRunFixtures.world(
            devices: devices, event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.departing.rawValue))
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
        let directive = EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now)
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
        let directive = EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now)
        #expect(EventRun.convoy(of: directive, in: world)?.courier?.deviceCode == "PRINTED")
        #expect(EventRun().nextAction(directive: directive, world: world) == .dispatch(
            kind: .attach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["PRINTED"]),
            nextStep: EventRun.Step.confirmingLoad.rawValue
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
            directive: EventRunFixtures.directive(step: EventRun.Step.preflight.rawValue, now: now), world: world
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
            directive: EventRunFixtures.directive(step: EventRun.Step.preflight.rawValue, now: now), world: world
        )
        #expect(action == .refreshFootprint(nextStep: EventRun.Step.preflight.rawValue, thenStall: nil))
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
            directive: EventRunFixtures.directive(step: EventRun.Step.loading.rawValue, now: now), world: world
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
    /// `orbital_mirror` is deliberately absent: it is one of the four component
    /// types the account holds no blueprint for.
    private let bills: [String: ResourceCost] = [
        "atmospheric_regulator": ResourceCost(structural: 200),
        "filtration_array": ResourceCost(structural: 140),
        "atmo_processor": ResourceCost(structural: 200),
        "climate_processor": ResourceCost(structural: 300),
        "reclamation_rig": ResourceCost(structural: 400),
        "coolant_loop": ResourceCost(structural: 90),
        "ftl_beacon": ResourceCost(structural: 50),
    ]
    /// `climate_processor` shares `atmo_processor` with the regulator, which is
    /// what makes a type both a top-level requirement and a sibling's component.
    private let components = [
        "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2],
        "climate_processor": ["atmo_processor": 2],
        "reclamation_rig": ["orbital_mirror": 1, "atmo_processor": 1],
    ]
    /// The live catalogue's spread: the regulator alone outruns the relay-shaped
    /// slack, so the deadline has to be derived rather than constant.
    private let printTimes = [
        "atmospheric_regulator": 3600, "filtration_array": 600, "atmo_processor": 600,
        "climate_processor": 4200, "reclamation_rig": 3600, "coolant_loop": 300,
        "ftl_beacon": 900,
    ]

    /// A depot printer reading fresher than the step, or `printing` buys a
    /// device read before it dispatches anything.
    private func factory(_ code: String = "FACTORY") -> Device {
        EventRunFixtures.device(code, type: "autofactory", updatedAt: now)
    }

    /// A printer reporting the shortfall a queued job is parked on.
    private func blockedFactory(
        _ shortfall: [String: (Int, Int)], _ code: String = "FACTORY"
    ) -> Device {
        var device = factory(code)
        device.detail = .object([
            "waiting_for": .object([
                "components": .object(shortfall.mapValues {
                    .object(["have": .number(Double($0.0)), "need": .number(Double($0.1))])
                })
            ])
        ])
        return device
    }

    /// `busy` printers carry a print THIS run dispatched; `foreign` ones carry
    /// somebody else's. `ordering` names what a busy printer is building, which
    /// is what the in-flight net reads.
    private func world(
        _ extraDevices: [Device], wanting: [(Int, String)] = [(1, "atmospheric_regulator")],
        busy: [String] = [], foreign: [String] = [],
        ordering: [String: (String, Int)] = [:], stepStartedAt: Date
    ) -> WorldSnapshot {
        var openOperations: [String: GameModels.Operation] = [:]
        var dispatched: [String: GameModels.Operation] = [:]
        for code in busy {
            let job = ordering[code]
            let ours = EventRunFixtures.openPrint(
                on: code, now: stepStartedAt, deviceType: job?.0, quantity: job?.1 ?? 1
            )
            openOperations.merge(ours) { _, latest in latest }
            for operation in ours.values { dispatched[operation.id] = operation }
        }
        for code in foreign {
            openOperations.merge(EventRunFixtures.openPrint(on: code, now: stepStartedAt)) {
                _, latest in latest
            }
        }
        return EventRunFixtures.world(
            devices: [
                EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
                EventRunFixtures.courier(),
            ] + extraDevices,
            event: EventRunFixtures.event(devices: wanting),
            now: now,
            openOperations: openOperations,
            dispatchedOperations: dispatched,
            blueprintBills: bills,
            blueprintComponents: components,
            blueprintPrintTimes: printTimes
        )
    }

    private func print(
        _ deviceType: String, _ quantity: Int, at deviceCode: String = "FACTORY"
    ) -> MissionAction {
        .dispatch(
            kind: .print, deviceCode: deviceCode,
            params: CommandParams(deviceType: deviceType, quantity: quantity, printTags: [tag.string]),
            nextStep: EventRun.Step.printing.rawValue
        )
    }

    @Test("printing dispatches a component before the device that consumes it")
    func componentsPrintFirst() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world([factory()], stepStartedAt: now)
        )
        #expect(action == print("atmo_processor", 2))
    }

    @Test("a component already standing under the run's tag is not reprinted")
    func standingComponentIsNetted() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world(
                [
                    factory(),
                    EventRunFixtures.device("AP1", type: "atmo_processor", tags: [tag.string]),
                    EventRunFixtures.device("AP2", type: "atmo_processor", tags: [tag.string]),
                ],
                stepStartedAt: now
            )
        )
        #expect(action == print("filtration_array", 1))
    }

    @Test("an untagged component of the standing fleet is never scavenged")
    func untaggedComponentIsNotNetted() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world(
                [
                    factory(),
                    EventRunFixtures.device("AP1", type: "atmo_processor", tags: []),
                    EventRunFixtures.device("AP2", type: "atmo_processor", tags: []),
                ],
                stepStartedAt: now
            )
        )
        #expect(action == print("atmo_processor", 2))
    }

    @Test("a standing parent suppresses the components it already consumed")
    func standingParentSuppressesItsComponents() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world(
                [
                    factory(),
                    EventRunFixtures.device("AR1", type: "atmospheric_regulator", tags: [tag.string]),
                    EventRunFixtures.device("OLDBEACON", type: "ftl_beacon", location: "X-1"),
                ],
                stepStartedAt: now
            )
        )
        #expect(
            action == .advanceStep(nextStep: EventRun.Step.loading.rawValue),
            "the regulator ate its own components — reprinting them buys nothing"
        )
    }

    /// One `atmo_processor` wanted outright plus a `climate_processor` that eats
    /// two more. Three held cover both demands; two cover only one of them, and
    /// a pool spent twice would wrongly read as covering both.
    @Test("held stock covering a top-level device and a sibling's tree is spent once")
    func heldStockIsSpentOnlyOnce() {
        func action(held: Int) -> MissionAction {
            EventRun().nextAction(
                directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
                world: world(
                    [factory()] + (0..<held).map {
                        EventRunFixtures.device("AP\($0)", type: "atmo_processor", tags: [tag.string])
                    },
                    wanting: [(1, "atmo_processor"), (1, "climate_processor")],
                    stepStartedAt: now
                )
            )
        }
        #expect(action(held: 3) == print("climate_processor", 1))
        #expect(
            action(held: 2) == print("atmo_processor", 1),
            "the one spent on the top level must not also count against the tree"
        )
    }

    // MARK: - One bill, however many printers

    /// Two free printers, the first tick's order already in flight. The second
    /// printer must take the NEXT job: `missingTree` counts only what STANDS at
    /// the depot, so without the in-flight net it re-orders the same bill.
    @Test("a second free printer never re-dispatches a job already in flight")
    func aSecondFreePrinterTakesOnlyNewWork() {
        let first = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world([factory(), factory("SPARE")], stepStartedAt: now)
        )
        #expect(first == print("atmo_processor", 2))

        let second = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world(
                [factory(), factory("SPARE")], busy: ["FACTORY"],
                ordering: ["FACTORY": ("atmo_processor", 2)], stepStartedAt: now
            )
        )
        #expect(
            second == print("filtration_array", 1, at: "SPARE"),
            "four autofactories used to mean four times the component bill"
        )
    }

    /// The whole bill in flight and a printer standing free, INSIDE the
    /// deadline: wait, rather than fly a payload the prints never filled.
    @Test("a free printer waits inside the deadline when the bill is all in flight")
    func aFreePrinterWaitsWhileTheBillIsInFlight() {
        #expect(nothingLeftToOrder(startedAgo: 60) == .wait)
    }

    /// The same state past the deadline. A free printer used to make the
    /// deadline unreachable, so a component-blocked print parked the run
    /// forever — the exact silent park this branch exists to close.
    @Test("a free printer with the bill all in flight still stalls past the deadline")
    func aFreePrinterStallsOnceTheInFlightPrintOutlivesTheDeadline() {
        let action = nothingLeftToOrder(startedAgo: EventRun.printSlack + 600 + 60)
        guard case .stall(let reason, _) = action else {
            Issue.record("expected a stall, got \(action)"); return
        }
        #expect(reason == .printBlockedOnComponents)
    }

    /// Two printers, one busy with this run's only remaining job and one free,
    /// so the dispatch guard falls through with nothing left to order.
    private func nothingLeftToOrder(startedAgo: TimeInterval) -> MissionAction {
        let started = now.addingTimeInterval(-startedAgo)
        return EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: started),
            world: world(
                [
                    factory(), factory("SPARE"),
                    EventRunFixtures.device("OLDBEACON", type: "ftl_beacon", location: "X-1"),
                ],
                wanting: [(2, "atmo_processor")], busy: ["FACTORY"],
                ordering: ["FACTORY": ("atmo_processor", 2)], stepStartedAt: started
            )
        )
    }

    /// Three free printers walk down the order rather than re-issuing its head,
    /// so a parent is enqueued while its own components are still printing. The
    /// server parks it in `waiting_for.components`; this pins that intent.
    @Test("three free printers walk the order rather than re-issuing its head")
    func threeFreePrintersWalkTheOrder() {
        func tick(_ inFlight: [String: (String, Int)]) -> MissionAction {
            EventRun().nextAction(
                directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
                world: world(
                    [factory(), factory("SPARE"), factory("THIRD")],
                    busy: Array(inFlight.keys), ordering: inFlight, stepStartedAt: now
                )
            )
        }
        #expect(tick([:]) == print("atmo_processor", 2))
        #expect(tick(["FACTORY": ("atmo_processor", 2)]) == print("filtration_array", 1, at: "SPARE"))
        #expect(
            tick([
                "FACTORY": ("atmo_processor", 2), "SPARE": ("filtration_array", 1),
            ]) == print("atmospheric_regulator", 1, at: "THIRD"),
            "the parent is ordered while its components print — the server queues it"
        )
    }

    // MARK: - A tree that cannot be built

    /// An option whose tree reaches `orbital_mirror`, which no blueprint prints.
    /// Printing the rest and departing spends hulls and resources on a payload
    /// that cannot satisfy the criteria.
    @Test("a tree reaching a blueprint-less device stalls and dispatches nothing")
    func unprintableTreeStalls() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world([factory()], wanting: [(1, "reclamation_rig")], stepStartedAt: now)
        )
        guard case .stall(let reason, let detail) = action else {
            Issue.record("expected a stall, got \(action)"); return
        }
        #expect(reason == .eventOptionBlueprintMissing)
        #expect(
            detail == "Orbital Mirror",
            "a device type is prose — the panel sets a designation in mono, not this"
        )
    }

    @Test("a fully printable tree still dispatches")
    func printableTreeStillDispatches() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world([factory()], wanting: [(1, "climate_processor")], stepStartedAt: now)
        )
        #expect(action == print("atmo_processor", 2))
    }

    // MARK: - The deadline

    /// 1,860 s in: past the old relay-shaped constant, well inside the
    /// regulator's own 3,600 s print. A healthy print must not surface.
    @Test("every printer busy inside the derived deadline waits")
    func aLongPrintOutlivesTheRelayShapedConstant() {
        let started = now.addingTimeInterval(-(EventRun.printSlack + 60))
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: started),
            world: world(
                [blockedFactory(["atmo_processor": (0, 2)])],
                busy: ["FACTORY"], stepStartedAt: started
            )
        )
        #expect(action == .wait)
    }

    /// The other side of the same rule: a print outliving its own run time plus
    /// the slack is stuck rather than slow, and must surface.
    @Test("every printer busy past the derived deadline stalls")
    func aPermanentlyBlockedPrintStalls() {
        let started = now.addingTimeInterval(-(EventRun.printSlack + 3600 + 60))
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: started),
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

    // MARK: - The server's own answer

    @Test("the server's own shortfall outranks the local expansion")
    func serverShortfallLeadsTheOrder() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world(
                [blockedFactory(["coolant_loop": (1, 3)]), factory("SPARE")],
                busy: ["FACTORY"], stepStartedAt: now
            )
        )
        #expect(action == print("coolant_loop", 2, at: "SPARE"))
    }

    /// The fold takes the GREATER of the two counts, so the magnitudes have to
    /// differ in BOTH directions for the `max` to be visible at all.
    @Test("the order takes the greater of the server's shortfall and the expansion")
    func theGreaterOfTheTwoCountsIsOrdered() {
        func action(serverShortfall: Int) -> MissionAction {
            EventRun().nextAction(
                directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
                world: world(
                    [blockedFactory(["atmo_processor": (0, serverShortfall)]), factory("SPARE")],
                    busy: ["FACTORY"], stepStartedAt: now
                )
            )
        }
        #expect(action(serverShortfall: 5) == print("atmo_processor", 5, at: "SPARE"))
        #expect(
            action(serverShortfall: 1) == print("atmo_processor", 2, at: "SPARE"),
            "the expansion is the greater one here"
        )
    }

    /// Another automation's — or the operator's — blocked print at the same
    /// depot must not steer this run's order or spend its budget.
    @Test("a blockage on a printer this run has no work on is ignored")
    func foreignBlockageDoesNotSteerTheOrder() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world(
                [blockedFactory(["coolant_loop": (1, 3)]), factory("SPARE")],
                foreign: ["FACTORY"], stepStartedAt: now
            )
        )
        #expect(action == print("atmo_processor", 2, at: "SPARE"))
    }

    /// `enqueue_print` for a type with no blueprint is refused every tick.
    @Test("a server-named type with no blueprint is dropped from the order")
    func unbillableServerShortfallIsDropped() {
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now),
            world: world(
                [blockedFactory(["orbital_mirror": (0, 2)]), factory("SPARE")],
                busy: ["FACTORY"], stepStartedAt: now
            )
        )
        #expect(action == print("atmo_processor", 2, at: "SPARE"))
    }
}
