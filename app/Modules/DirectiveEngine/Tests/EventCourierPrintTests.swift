//
//  EventCourierPrintTests.swift
//  Replicould — DirectiveEngine
//
//  Covers the courier bootstrap: print the container, replicate, stow, confirm.
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

    private func world(_ devices: [Device], hosts: Set<String> = []) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: [:],
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
            EventRunFixtures.device("BOX", type: "matrix_container", tags: [EventRun.rootTag], updatedAt: now),
        ]
    }

    @Test("with no container at the depot, it prints one")
    func printsContainer() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.printing),
            world: world([EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now)])
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: "matrix_container", quantity: 1, printTags: [EventRun.rootTag]
            ),
            nextStep: EventCourierPrint.Step.awaitingClone
        ))
    }

    @Test("with a container standing, it replicates into the spare matrix")
    func replicates() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating),
            world: world(standing() + [spareMatrix()])
        )
        #expect(action == .dispatch(
            kind: .simple("replicate"), deviceCode: "MATRIX",
            params: CommandParams(), nextStep: EventCourierPrint.Step.stowing
        ))
    }

    @Test("a hosted courier finishes the run")
    func finishes() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "BOX"
        let hosted = world(standing() + [matrix], hosts: ["BOX"])
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.stowing), world: hosted
        )
        #expect(action == .done)
        #expect(EventCourierPrint.courierStands(at: "HUB-1", in: hosted))
    }

    @Test("no spare matrix stalls rather than printing a 14,400s one silently")
    func noSpareMatrix() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating), world: world(standing())
        )
        #expect(action == .stall(.unreachableDevice, detail: "no empty replicant matrix at HUB-1"))
    }

    @Test("a fresh replicant is stowed into the container, then confirmed")
    func stows() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: "HUB-1")
        matrix.features = ["stow", "matrix"]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.stowing),
            world: world(standing() + [matrix], hosts: ["MATRIX"])
        )
        #expect(action == .dispatch(
            kind: .stow, deviceCode: "MATRIX", params: CommandParams(target: "BOX"),
            nextStep: EventCourierPrint.Step.confirmingStow
        ))
    }

    @Test("a stow that never lands stalls instead of re-issuing forever")
    func stowStalls() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: "HUB-1")
        matrix.features = ["stow", "matrix"]
        let entered = now.addingTimeInterval(-EventCourierPrint.stowConfirmDeadline - 1)
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.confirmingStow, entered: entered),
            world: world(standing() + [matrix], hosts: ["MATRIX"])
        )
        #expect(action == .refreshDevices(deviceCodes: ["MATRIX"], thenStall: .commandRejected))
    }

    @Test("a replicate that produced nothing hands back rather than waiting forever")
    func replicateNeverLanded() {
        let entered = now.addingTimeInterval(-EventCourierPrint.replicateDeadline - 1)
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.stowing, entered: entered),
            world: world(standing() + [spareMatrix()])
        )
        #expect(action == .advanceStep(nextStep: EventCourierPrint.Step.replicating))
    }
}
