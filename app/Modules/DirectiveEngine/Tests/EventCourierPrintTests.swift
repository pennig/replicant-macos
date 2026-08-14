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

    /// The courier's new replicant, in a spare cradle at the depot: an occupied
    /// matrix plus the `matrix_container` holding it.
    private func replicated() -> [Device] {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "CRADLE"
        var cradle = EventRunFixtures.device("CRADLE", type: "matrix_container", updatedAt: now)
        cradle.features = ["cruise", "cradle"]
        return [matrix, cradle]
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

    @Test("once the operator has replicated, the run resumes at stowing")
    func resumesAfterReplication() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating),
            world: world(standing() + replicated())
        )
        #expect(action == .advanceStep(nextStep: EventCourierPrint.Step.stowing))
    }

    @Test("a vessel's own replicant is never mistaken for the courier's")
    func neverRaidsAVessel() {
        let racer = EventRunFixtures.device("RACER", type: "racing_vessel", updatedAt: now)
        let fleet = standing() + residentVessel() + [racer]
        let hosts: Set<String> = ["HEAVEN", "RACER"]
        let asked = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating),
            world: world(fleet + [spareMatrix()], hosts: hosts)
        )
        #expect(asked == .stall(.awaitingCourierReplication, detail: "HUB-1"))

        let stowed = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.stowing),
            world: world(fleet + replicated(), hosts: hosts)
        )
        #expect(stowed == .dispatch(
            kind: .stow, deviceCode: "MATRIX", params: CommandParams(target: "BOX"),
            nextStep: EventCourierPrint.Step.confirmingStow
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
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.stowing),
            world: world(standing() + replicated())
        )
        #expect(action == .dispatch(
            kind: .stow, deviceCode: "MATRIX", params: CommandParams(target: "BOX"),
            nextStep: EventCourierPrint.Step.confirmingStow
        ))
    }

    @Test("a stow that never lands stalls instead of re-issuing forever")
    func stowStalls() {
        let entered = now.addingTimeInterval(-EventCourierPrint.stowConfirmDeadline - 1)
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.confirmingStow, entered: entered),
            world: world(standing() + replicated())
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
