//
//  ReturnHomeTests.swift
//  Replicould — DirectiveEngine
//
//  Going home: arrived, in flight, and the three-way no-destination rule.
//

import Foundation
import GameModels
import GameServices
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)
private let depot = "AINALRAM-BELT-1"

private func row(theatreDepot: String?, origin: String? = nil) -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: "C1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["SOL"], targetIndex: 0, step: "returning",
        stepStartedAt: now.addingTimeInterval(-60), returnToOrigin: origin != nil,
        originDesignation: origin, attentionReason: nil,
        createdAt: now.addingTimeInterval(-3_600), updatedAt: now, theatreDepot: theatreDepot
    )
}

private func carrier(at location: String?) -> Device {
    Device(
        deviceCode: "C1", deviceType: "surge_carrier", replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object([:]),
        updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func ctx(_ device: Device, _ directive: Directive, theatres: [Theatre] = []) -> StepContext {
    StepContext(
        directive: directive,
        world: WorldSnapshot(
            devices: [device.deviceCode: device], openOperations: [:],
            theatres: theatres, now: now
        ),
        step: "returning"
    )
}

@Suite("Return home")
struct ReturnHomeTests {
    private let home = ReturnHome(deviceCodes: ["C1"], destination: .theatreDepot)

    @Test("standing at the depot is finished")
    func standingAtTheDepotIsFinished() {
        let theatres = singleOperationalTheatre(depot: depot).theatres
        let result = home.next(ctx(carrier(at: depot), row(theatreDepot: depot), theatres: theatres))
        #expect(result == .finished)
    }

    @Test("away from the depot it flies")
    func awayFromTheDepotItFlies() {
        let theatres = singleOperationalTheatre(depot: depot).theatres
        let result = home.next(ctx(carrier(at: "VEGA-1"), row(theatreDepot: depot), theatres: theatres))
        #expect(result == .action(.dispatch(
            kind: .travel, deviceCode: "C1",
            params: CommandParams(destination: depot), nextStep: "returning"
        )))
    }

    /// No depot at all is the mission's call — leave the hull where it stands,
    /// or wait. `.noSubject` is what keeps that decision out of here.
    @Test("no depot is no subject, never a stall")
    func noDepotIsNoSubject() {
        #expect(home.next(ctx(carrier(at: "VEGA-1"), row(theatreDepot: nil))) == .noSubject)
    }

    /// A row whose own theatre went `.claimed` while another stands
    /// `.operational` waits for it rather than flying somewhere else.
    @Test("a claimed theatre waits instead of reporting no subject")
    func aClaimedTheatreWaits() {
        let elsewhere = singleOperationalTheatre(depot: "DENEBED-2").theatres
        let result = home.next(ctx(carrier(at: "VEGA-1"), row(theatreDepot: depot), theatres: elsewhere))
        #expect(result == .action(.wait))
    }

    /// Survey aims at `originDesignation`, a bare SYSTEM, and matches at
    /// system level — the only site that does.
    @Test("the origin destination matches at system level")
    func theOriginDestinationMatchesAtSystemLevel() {
        let toOrigin = ReturnHome(deviceCodes: ["C1"], destination: .origin)
        let result = toOrigin.next(ctx(carrier(at: "SOL-3"), row(theatreDepot: nil, origin: "SOL")))
        #expect(result == .finished)
    }

    /// One hull moves per evaluation; the other's turn comes next tick.
    @Test("with two hulls only the one that needs moving is commanded")
    func onlyOneHullMovesPerEvaluation() {
        let pair = ReturnHome(deviceCodes: ["C1", "F1"], destination: .theatreDepot)
        let freighter = Device(
            deviceCode: "F1", deviceType: "cargo_freighter", replicantCode: "R1", status: "idle",
            location: "VEGA-1", locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
            features: [], tags: [], detail: .object([:]),
            updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
        let world = WorldSnapshot(
            devices: ["C1": carrier(at: depot), "F1": freighter], openOperations: [:],
            theatres: singleOperationalTheatre(depot: depot).theatres, now: now
        )
        let result = pair.next(StepContext(
            directive: row(theatreDepot: depot), world: world, step: "returning"
        ))
        #expect(result == .action(.dispatch(
            kind: .travel, deviceCode: "F1",
            params: CommandParams(destination: depot), nextStep: "returning"
        )))
    }
}
