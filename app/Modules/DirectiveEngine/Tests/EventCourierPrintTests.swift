//
//  EventCourierPrintTests.swift
//  Replicould — DirectiveEngine
//
//  Covers the courier bootstrap: print the container, ask the operator, finish.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("EventCourierPrint")
struct EventCourierPrintTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func directive(step: String, entered: Date? = nil) -> Directive {
        Directive(
            id: "c1", kind: .eventCourierPrint, status: .running, deviceCode: "PRINTER",
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
            targets: [], targetIndex: 0, step: step, stepStartedAt: entered ?? now,
            returnToOrigin: false, originDesignation: nil, attentionReason: nil,
            createdAt: now, updatedAt: now, theatreDepot: "HUB-1"
        )
    }

    private func world(
        _ devices: [Device], hosts: Set<String> = [],
        openOperations: [String: GameModels.Operation] = [:],
        dispatchedOperations: [String: GameModels.Operation] = [:]
    ) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: openOperations,
            dispatchedOperations: dispatchedOperations,
            footprints: [
                "HUB-1": LocationFootprint(
                    location: "HUB-1", devices: devices.count, resources: 500_000,
                    resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
                )
            ],
            theatres: [Theatre(depot: "HUB-1", system: "HUB", origin: .derived,
                               readiness: .operational, stock: 500_000)],
            replicantHostDevices: hosts,
            now: now
        )
    }

    /// A spare matrix: it still carries the `matrix` feature and the verb.
    private func spareMatrix() -> Device {
        var matrix = EventRunFixtures.device("MATRIX", type: "empty_replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.availableCommands = ["replicate"]
        return matrix
    }

    private func standing() -> [Device] {
        [
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
            EventRunFixtures.device("BOX", type: "matrix_container", tags: [EventRun.rootTag.string], updatedAt: now),
        ]
    }

    /// A heaven vessel at the depot carrying its own resident replicant — the
    /// shape a depot-only scope cannot tell from the courier's.
    private func residentVessel() -> [Device] {
        var matrix = EventRunFixtures.device("ANCHOR", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "HEAVEN"
        var vessel = EventRunFixtures.device("HEAVEN", type: "heaven_vessel", updatedAt: now)
        vessel.features = ["cradle", "surge"]
        return [matrix, vessel]
    }

    @Test("with no container at the depot, it prints one")
    func printsContainer() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.printing.rawValue),
            world: world([EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now)])
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: "matrix_container", quantity: 1, printTags: [EventRun.rootTag.string]
            ),
            nextStep: EventCourierPrint.Step.awaitingClone.rawValue
        ))
    }

    @Test("with a container standing, it asks the operator to replicate")
    func asksForReplication() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating.rawValue),
            world: world(standing() + [spareMatrix()])
        )
        #expect(action == .stall(.awaitingCourierReplication, detail: "HUB-1"))
        #expect(DirectiveAttentionReason.awaitingCourierReplication.brainDisposition == .escalate)
    }

    @Test("a vessel's own replicant is never mistaken for a courier")
    func neverRaidsAVessel() {
        let racer = EventRunFixtures.device("RACER", type: "racing_vessel", updatedAt: now)
        let fleet = standing() + residentVessel() + [racer, spareMatrix()]
        let peopled = world(fleet, hosts: ["HEAVEN", "RACER"])
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating.rawValue), world: peopled
        )
        #expect(action == .stall(.awaitingCourierReplication, detail: "HUB-1"))
        #expect(!EventCourierPrint.courierStands(at: "HUB-1", in: peopled))
    }

    @Test("a hosted courier finishes the run")
    func finishes() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "BOX"
        let hosted = world(standing() + [matrix], hosts: ["BOX"])
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating.rawValue), world: hosted
        )
        #expect(action == .done)
        #expect(EventCourierPrint.courierStands(at: "HUB-1", in: hosted))
    }

    @Test("no spare matrix stalls rather than printing a 14,400s one silently")
    func noSpareMatrix() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating.rawValue), world: world(standing())
        )
        #expect(action == .stall(.unreachableDevice, detail: "no empty replicant matrix at HUB-1"))
    }

    /// A container hosting another automation's replicant, never printed here.
    private func anchorContainer() -> Device {
        EventRunFixtures.device("ANCHOR", type: "matrix_container", updatedAt: now)
    }

    @Test("a hosted container we never printed does not stand as a courier")
    func courierStandsWantsBothHalves() {
        // `standing()`'s BOX is the other half: printed here, nobody in it yet.
        let mixed = world(standing() + [anchorContainer()], hosts: ["ANCHOR"])
        #expect(!EventCourierPrint.courierStands(at: "HUB-1", in: mixed))
    }

    @Test("a courier aboard a carrier at the depot stands, however stale its own row")
    func standsThroughItsHost() {
        var carrier = EventRunFixtures.device("CARRIER", type: "surge_carrier", updatedAt: now)
        carrier.features = ["cradle", "surge"]
        let riding = EventRunFixtures.courier(attachedTo: "CARRIER", location: "FAR-3")
        #expect(EventCourierPrint.courierStands(at: "HUB-1", in: world([carrier, riding], hosts: ["COURIER"])))
    }

    @Test("a courier aboard a carrier that is away does not stand")
    func doesNotStandAboardAnAbsentCarrier() {
        var carrier = EventRunFixtures.device(
            "CARRIER", type: "surge_carrier", location: "FAR-3", updatedAt: now
        )
        carrier.features = ["cradle", "surge"]
        let riding = EventRunFixtures.courier(attachedTo: "CARRIER", location: "HUB-1")
        #expect(!EventCourierPrint.courierStands(at: "HUB-1", in: world([carrier, riding], hosts: ["COURIER"])))
    }

    @Test("it prints its own container rather than claiming an untagged one")
    func printsPastAnotherAutomationsContainer() {
        let fleet = [
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
            anchorContainer(),
        ]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.printing.rawValue),
            world: world(fleet, hosts: ["ANCHOR"])
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: "matrix_container", quantity: 1, printTags: [EventRun.rootTag.string]
            ),
            nextStep: EventCourierPrint.Step.awaitingClone.rawValue
        ))
    }

    @Test("a row stranded on an unknown step waits rather than rejoining the machine")
    func unknownStepWaits() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: "stowing"), world: world(standing() + [spareMatrix()])
        )
        #expect(action == .wait)
    }

    /// A co-tenant's job leaves real depth to spare, so the run queues its own
    /// print behind it rather than waiting for the bench to clear.
    @Test("a co-tenant's print at the printer does not block a courier print")
    func coTenantPrintWaitsRatherThanDispatching() {
        let openOperations = ["PRINTER": GameModels.Operation(
            id: "OP-OTHER", entityCode: "PRINTER", kind: OperationKind.print.rawValue,
            status: .active, source: .poll, startedAt: now, completesAt: nil,
            lastConfirmedAt: now, detail: .object([:]), directiveID: "OTHER"
        )]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.printing.rawValue),
            world: world(
                [EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now, queueSize: 10)],
                openOperations: openOperations
            )
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: EventRun.courierDeviceType, quantity: 1, printTags: [EventRun.rootTag.string]
            ),
            nextStep: EventCourierPrint.Step.awaitingClone.rawValue
        ))
    }

    /// Every bench busy is the system working, not a fault — two printers,
    /// each already AT capacity (`queueSize: 1`, explicit rather than an
    /// accident of the unset default) on another directive's job, must wait.
    @Test("an all-busy depot waits, it does not stall")
    func allBusyWaits() {
        let openOperations: [String: GameModels.Operation] = [
            "PRINTER": GameModels.Operation(
                id: "OP-1", entityCode: "PRINTER", kind: OperationKind.print.rawValue,
                status: .active, source: .poll, startedAt: now, completesAt: nil,
                lastConfirmedAt: now, detail: .object([:]), directiveID: "OTHER"
            ),
            "PRINTER2": GameModels.Operation(
                id: "OP-2", entityCode: "PRINTER2", kind: OperationKind.print.rawValue,
                status: .active, source: .poll, startedAt: now, completesAt: nil,
                lastConfirmedAt: now, detail: .object([:]), directiveID: "OTHER"
            ),
        ]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.printing.rawValue),
            world: world(
                [
                    EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now, queueSize: 1),
                    EventRunFixtures.device("PRINTER2", type: "autofactory", updatedAt: now, queueSize: 1),
                ],
                openOperations: openOperations
            )
        )
        #expect(action == .wait)
    }

    /// A depot with no print-capable device at all is still a fault, distinct
    /// from `noSpareMatrix` above — this is the printing step, not replicating.
    @Test("a depot with no bench stalls")
    func noBenchStalls() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.printing.rawValue),
            world: world([EventRunFixtures.device("X1", type: "generic_device", updatedAt: now)])
        )
        #expect(action == .stall(.unreachableDevice))
    }

    /// Our own print, still open, holds the step.
    @Test("waiting on the clone holds while our own print is open")
    func awaitingCloneWaitsOnOwnPrint() {
        let openOperations = ["PRINTER": GameModels.Operation(
            id: "OP-c1", entityCode: "PRINTER", kind: OperationKind.print.rawValue,
            status: .active, source: .poll, startedAt: now, completesAt: nil,
            lastConfirmedAt: now, detail: .object([:]), directiveID: "c1"
        )]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.awaitingClone.rawValue),
            world: world(
                [EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now)],
                openOperations: openOperations
            )
        )
        #expect(action == .wait)
    }

    /// The pin refused the job, so the print went to a substitute bench. The
    /// poll must find it there; watching the pin's own queue would re-decide
    /// and, with a free bench standing by, order a second courier.
    @Test("waiting on the clone holds while our print sits on a substitute bench")
    func awaitingCloneWatchesTheSubstituteBench() {
        var pin = EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now)
        pin.status = "compacted"
        let mine = GameModels.Operation(
            id: "OP-AF2", entityCode: "AF2", kind: OperationKind.print.rawValue,
            status: .active, source: .poll, startedAt: now, completesAt: nil,
            lastConfirmedAt: now, detail: .object([:]), directiveID: "c1"
        )
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.awaitingClone.rawValue),
            world: world(
                [
                    pin,
                    EventRunFixtures.device("AF2", type: "autofactory", updatedAt: now),
                    EventRunFixtures.device("AF3", type: "autofactory", updatedAt: now),
                ],
                openOperations: ["AF2": mine], dispatchedOperations: ["OP-AF2": mine]
            )
        )
        #expect(action == .wait)
    }

    /// **The load-bearing case.** Our own print, still nominally open, must not
    /// extend the wait past the deadline — the deadline is a hard ceiling.
    @Test("a print that produced no clone past the deadline re-decides")
    func awaitingCloneReDecidesPastDeadline() {
        let stale = now.addingTimeInterval(-(PrintJob.deadline + 60))
        let openOperations = ["PRINTER": GameModels.Operation(
            id: "OP-c1", entityCode: "PRINTER", kind: OperationKind.print.rawValue,
            status: .active, source: .poll, startedAt: now, completesAt: nil,
            lastConfirmedAt: now, detail: .object([:]), directiveID: "c1"
        )]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.awaitingClone.rawValue, entered: stale),
            world: world(
                [EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now)],
                openOperations: openOperations
            )
        )
        #expect(action == .advanceStep(nextStep: EventCourierPrint.Step.printing.rawValue))
    }

    @Test func stepVocabularyIsFrozen() {
        #expect(
            EventCourierPrint.Step.allCases.map(\.rawValue)
                == ["printing", "awaitingClone", "replicating"]
        )
    }
}
