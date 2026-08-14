import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

@Suite("EventRun — loading")
struct EventRunLoadingTests {
    // Fixtures shared with the later EventRun suites.
    static func device(
        _ code: String, type: String, location: String? = "HUB-1",
        attachedTo: String? = nil, tags: [String] = [], updatedAt: Date = .distantPast,
        cargoUsed: Int? = nil
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R-1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 1, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: attachedTo,
            createdAt: .distantPast, availableCommands: [], features: [], tags: tags,
            detail: cargoUsed.map { .object(["cargo_used": .number(Double($0))]) } ?? .object([:]),
            updatedAt: updatedAt, firstSeenAt: .distantPast
        )
    }

    static func openPrint(on code: String, now: Date) -> [String: GameModels.Operation] {
        [code: GameModels.Operation(
            id: "OP-1", entityCode: code, kind: OperationKind.print.rawValue, status: .active,
            source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now,
            detail: .object([:])
        )]
    }

    static func directive(step: String, now: Date) -> Directive {
        Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
            controllerCode: nil, roamCentre: nil,
            fleetTag: EventRun.fleetTag(forTheatre: "HUB-1"), sourceRelayCode: nil,
            targets: ["X-1-EVT-001"], targetIndex: 0, step: step,
            stepStartedAt: now, returnToOrigin: true, originDesignation: "HUB",
            attentionReason: nil, createdAt: now, updatedAt: now,
            theatreDepot: "HUB-1", freighterCode: "FREIGHT"
        )
    }

    static func event(resources: [String: Int], devices: [(Int, String)]) -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 1, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("default"),
                    "devices": .array(devices.map {
                        .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
                    }),
                    "resources": .object(resources.mapValues { .number(Double($0)) }),
                ])]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    static func world(
        devices: [Device], event: LocationEvent, now: Date,
        footprintFresh: Bool = true, stock: Int = 500_000,
        openOperations: [String: GameModels.Operation] = [:]
    ) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: openOperations,
            footprints: [
                "HUB-1": LocationFootprint(
                    location: "HUB-1", devices: devices.count, resources: stock,
                    resourceSites: 0, locationEvents: 0, replicants: 0,
                    fetchedAt: footprintFresh ? now : .distantPast
                )
            ],
            theatres: [
                Theatre(depot: "HUB-1", system: "HUB", origin: .derived,
                        readiness: .operational, stock: stock)
            ],
            locationEvents: [event.designation: event],
            now: now
        )
    }

    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("preflight prints the beacon when the location has none")
    func printsBeacon() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.preflight, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.printing))
    }

    @Test("printing enqueues the beacon at the depot printer")
    func enqueuesBeacon() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
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
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
            Self.device("OLDBEACON", type: "ftl_beacon", location: "X-1"),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading))
    }

    @Test("the reserve rail vetoes a print rather than spending")
    func railVetoes() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []),
            now: now, stock: 1
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("loading attaches the courier first, one attach per round")
    func attachesCourier() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("BEACON", type: "ftl_beacon", tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
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
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
            Self.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
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
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }

    @Test("a device roster older than the step buys one authoritative read first")
    func staleFleetEvidenceReadsBeforePrinting() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory"),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .refreshDevicesInSystem(
            designation: "HUB-1", thenStall: .unreachableDevice
        ))
    }

    @Test("a tagged beacon already waiting at the depot is not printed again")
    func skipsBeaconStandingAtTheDepot() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
            Self.device("BEACON", type: "ftl_beacon",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading))
    }

    @Test("a print already in flight at the printer is not doubled")
    func waitsOnAnOpenPrint() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []),
            now: now, openOperations: Self.openPrint(on: "PRINTER", now: now)
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("a missing freighter re-reads the fleet rather than stalling")
    func noFreighterRereadsTheFleet() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }

    @Test("a hold already carrying something departs rather than collecting twice")
    func partiallyLoadedHoldDeparts() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter", cargoUsed: 120),
            Self.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
            Self.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.departing))
    }

    @Test("a container attached to another carrier is not this run's courier")
    func ignoresACourierAboardAnotherCarrier() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("OTHER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("COURIER", type: "matrix_container", attachedTo: "OTHER"),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }
}
