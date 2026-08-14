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

    @Test("with a container standing, it asks the operator to replicate")
    func asksForReplication() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating),
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
            directive: directive(step: EventCourierPrint.Step.replicating), world: peopled
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
            directive: directive(step: EventCourierPrint.Step.replicating), world: hosted
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

    @Test("a row stranded on a retired step rejoins the machine")
    func unknownStepRejoins() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: "stowing"), world: world(standing() + [spareMatrix()])
        )
        #expect(action == .advanceStep(nextStep: EventCourierPrint.Step.replicating))
    }
}
