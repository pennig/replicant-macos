//
//  FetchRunTests.swift
//  Replicould — DirectiveEngine
//
//  The fetch machine: plate selection, the staging ladder, and the flight.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels

@testable import DirectiveEngine

/// SOL at the origin, VEGA 10 away, RIGEL 100. Pinned absolutely so a ranking
/// assertion cannot pass by coincidence.
private let fetchPositions: [String: Position] = [
    "SOL": Position(x: 0, y: 0, z: 0),
    "VEGA": Position(x: 10, y: 0, z: 0),
    "RIGEL": Position(x: 100, y: 0, z: 0),
]

/// The snapshot is at t=1000 and `stagingFreshness` is 300s, so a row read at
/// t=900 is believed and one at t=600 is stale. Both pinned, not derived.
private let fetchNow = Date(timeIntervalSince1970: 1_000)
private let fresh = Date(timeIntervalSince1970: 900)
private let stale = Date(timeIntervalSince1970: 600)

private func fetchTheatre(
    _ depot: String, system: String, readiness: Theatre.Readiness = .operational
) -> Theatre {
    Theatre(depot: depot, system: system, origin: .derived, readiness: readiness, stock: 1_000)
}

/// `theatreResolver` is derived by `WorldSnapshot.init` from `theatres` and
/// `starPositions`, so passing those two is enough.
private func fetchWorld(
    _ devices: [Device],
    theatres: [Theatre] = [],
    openOperations: [String: GameModels.Operation] = [:],
    modularDeviceTypes: Set<String> = [],
    peers: [Directive] = [],
    now: Date = fetchNow
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations,
        starPositions: fetchPositions,
        modularDeviceTypes: modularDeviceTypes,
        theatres: theatres,
        peers: peers,
        now: now
    )
}

/// An eligible plate: tagged, with attach capacity to spare, read recently
/// enough that preflight will believe the row.
private func plateFixture(
    code: String = "PLATE1",
    location: String? = "SOL-3",
    tags: [String] = ["fetch"],
    capacity: Double = 2,
    attached: [String] = [],
    updatedAt: Date = fresh
) -> Device {
    var plate = deviceFixture(
        code: code, type: "surge_plate", location: location, tags: tags, updatedAt: updatedAt
    )
    plate.detail = .object([
        "attach_capacity": .number(capacity),
        "attached_devices": .array(attached.map { .string($0) }),
    ])
    return plate
}

private func payloadFixture(
    location: String? = "VEGA-2",
    status: String = "idle",
    attachedTo: String? = nil,
    updatedAt: Date = fresh
) -> Device {
    var payload = deviceFixture(
        code: "PAYLOAD1", type: "autofactory", location: location, status: status,
        updatedAt: updatedAt
    )
    payload.attachedToDeviceCode = attachedTo
    return payload
}

/// A fetch-run row as `Directive.launch` writes one, on `step`.
private func fetchRunFixture(
    step: FetchRun.Step,
    pickup: String = "VEGA-2",
    destination: String = "SOL-3",
    payload: String? = "PAYLOAD1",
    stepStartedAt: Date = fetchNow
) -> Directive {
    var directive = directiveFixture(
        id: "F1", kind: .fetchRun, deviceCode: "PLATE1", targets: [pickup, destination]
    )
    directive.payloadCode = payload
    directive.step = step.rawValue
    directive.stepStartedAt = stepStartedAt
    return directive
}

/// `WorldSnapshot.openOperations` is keyed by ENTITY code, not operation id.
private func busy(_ code: String, kind: OperationKind, id: String = "OP1") -> GameModels.Operation {
    GameModels.Operation(
        id: id, entityCode: code, kind: kind.rawValue, status: .active, source: .optimistic,
        startedAt: fresh, completesAt: Date(timeIntervalSince1970: 2_000),
        lastConfirmedAt: fresh, detail: .object([:])
    )
}

// MARK: - Plate selection

@Suite("FetchRun — plate selection")
struct FetchRunPlateTests {
    private func pick(_ devices: [Device], reserved: Set<String> = []) -> Device? {
        FetchRun.plate(for: "VEGA-2", in: devices, reserved: reserved, positions: fetchPositions)
    }

    /// Nearest to the PICKUP, between star positions: VEGA is 10 from SOL and
    /// 90 from RIGEL, so the SOL plate wins outright.
    @Test func picksTheNearestEligiblePlate() {
        #expect(pick([
            plateFixture(code: "PLATE-RIGEL", location: "RIGEL-1"),
            plateFixture(code: "PLATE-SOL", location: "SOL-3"),
        ])?.deviceCode == "PLATE-SOL")
    }

    /// A total order, so the answer cannot flicker with dictionary iteration.
    @Test func breaksATieOnDeviceCode() {
        #expect(pick([
            plateFixture(code: "PLATE-B", location: "SOL-3"),
            plateFixture(code: "PLATE-A", location: "SOL-1"),
        ])?.deviceCode == "PLATE-A")
    }

    @Test func refusesAPlateAlreadyLeased() {
        #expect(pick([plateFixture(code: "PLATE-SOL")], reserved: ["PLATE-SOL"]) == nil)
    }

    /// `fetch` is a bare tag, not a `FleetTag` — an `auto:` form must not match.
    @Test func refusesAnUntaggedPlate() {
        #expect(pick([
            plateFixture(code: "PLATE-BARE", tags: []),
            plateFixture(code: "PLATE-AUTO", tags: ["auto:fetch"]),
        ]) == nil)
    }

    @Test func refusesAPlateWithNoFreeAttachSlot() {
        #expect(pick([plateFixture(capacity: 1, attached: ["SOMETHING"])]) == nil)
    }

    @Test func refusesADeviceThatIsNotASurgePlate() {
        var carrier = deviceFixture(
            code: "CARRIER", type: "surge_carrier", location: "SOL-3", tags: ["fetch"]
        )
        carrier.detail = .object(["attach_capacity": .number(4)])
        #expect(pick([carrier]) == nil)
    }

    @Test func refusesAStowedPlateThatHasNoLocation() {
        #expect(pick([plateFixture(location: nil)]) == nil)
    }

    /// A plate whose system the census has never placed is still a usable hull;
    /// it just sorts last.
    @Test func aPlateWithAnUnknownPositionSortsLastRatherThanBeingExcluded() {
        let known = plateFixture(code: "PLATE-SOL", location: "SOL-3")
        let unknown = plateFixture(code: "PLATE-AAA", location: "NOWHERE-1")
        #expect(pick([unknown, known])?.deviceCode == "PLATE-SOL")
        #expect(pick([unknown])?.deviceCode == "PLATE-AAA")
    }
}

// MARK: - Preflight

@Suite("FetchRun — preflight")
struct FetchRunPreflightTests {
    private let run = FetchRun()

    @Test func advancesToStagingWhenBothRowsAreFreshAndTheLeaseIsClean() {
        let world = fetchWorld([plateFixture(), payloadFixture()])
        #expect(run.nextAction(directive: fetchRunFixture(step: .preflight), world: world)
            == .advanceStep(nextStep: FetchRun.Step.staging.rawValue))
    }

    /// t=600 against a t=1000 snapshot is 400s old, past the 300s window.
    @Test func buysAReadWhenTheRowsAreStale() {
        let world = fetchWorld([
            plateFixture(updatedAt: stale), payloadFixture(updatedAt: stale),
        ])
        #expect(run.nextAction(directive: fetchRunFixture(step: .preflight), world: world)
            == .refreshDevices(deviceCodes: ["PLATE1", "PAYLOAD1"], thenStall: nil))
    }

    @Test func stallsUnreachableWhenThePayloadRowIsMissing() {
        let world = fetchWorld([plateFixture()])
        #expect(run.nextAction(directive: fetchRunFixture(step: .preflight), world: world)
            == .refreshDevices(deviceCodes: ["PLATE1", "PAYLOAD1"], thenStall: .unreachableDevice))
    }

    /// The plate lost its tag between launch and preflight. The run does not
    /// re-pick — `deviceCode` is the lease.
    @Test func stallsWhenThePlateIsNoLongerEligible() {
        let world = fetchWorld([plateFixture(tags: []), payloadFixture()])
        #expect(run.nextAction(directive: fetchRunFixture(step: .preflight), world: world)
            == .stall(.noFetchPlateAvailable))
    }

    /// A peer directive holds the payload. Surface it; never take it back.
    @Test func stallsWhenAPeerDirectiveHoldsThePayload() {
        let directive = fetchRunFixture(step: .preflight)
        let rival = directiveFixture(id: "A0", kind: .salvageRun, deviceCode: "PAYLOAD1")
        let world = fetchWorld(
            [plateFixture(), payloadFixture()], peers: [directive, rival]
        )
        #expect(run.nextAction(directive: directive, world: world)
            == .stall(.fetchPayloadLeased, detail: "A0"))
    }

    /// `peers` carries this run's own row, so without the self-exclusion every
    /// fetch run would stall on its own lease.
    @Test func doesNotStallOnItsOwnPayloadLease() {
        let directive = fetchRunFixture(step: .preflight)
        let world = fetchWorld([plateFixture(), payloadFixture()], peers: [directive])
        #expect(run.nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: FetchRun.Step.staging.rawValue))
    }

    /// Someone moved the device by hand. Nothing left to do.
    @Test func completesWhenThePayloadAlreadyStandsAtTheDestination() {
        let world = fetchWorld([plateFixture(), payloadFixture(location: "SOL-3")])
        #expect(run.nextAction(directive: fetchRunFixture(step: .preflight), world: world) == .done)
    }
}

// MARK: - Staging

@Suite("FetchRun — staging")
struct FetchRunStagingTests {
    private let run = FetchRun()

    private func world(
        payloadStatus: String = "idle",
        plateLocation: String = "SOL-3",
        modular: Bool = true,
        openOperations: [String: GameModels.Operation] = [:]
    ) -> WorldSnapshot {
        fetchWorld(
            [plateFixture(location: plateLocation), payloadFixture(status: payloadStatus)],
            openOperations: openOperations,
            modularDeviceTypes: modular ? ["autofactory"] : []
        )
    }

    /// Rung 1. The compaction goes out first so it runs UNDER the plate's
    /// flight rather than after it.
    @Test func firstEvaluationCompactsAModularPayload() {
        #expect(run.nextAction(directive: fetchRunFixture(step: .staging), world: world())
            == .dispatch(
                kind: .compact, deviceCode: "PAYLOAD1", params: CommandParams(),
                nextStep: FetchRun.Step.staging.rawValue
            ))
    }

    /// Rung 2, and the point of the whole design: the plate launches while the
    /// compaction is still open. A sequential machine would wait here.
    @Test func secondEvaluationFliesThePlateWhileTheCompactionIsStillOpen() {
        let action = run.nextAction(
            directive: fetchRunFixture(step: .staging),
            world: world(
                payloadStatus: "compacting",
                openOperations: ["PAYLOAD1": busy("PAYLOAD1", kind: .compact)]
            )
        )
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "PLATE1",
            params: CommandParams(destination: "VEGA-2"),
            nextStep: FetchRun.Step.staging.rawValue
        ))
    }

    @Test func aNonModularPayloadIsNeverCompacted() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .staging), world: world(modular: false)
        ) == .dispatch(
            kind: .travel, deviceCode: "PLATE1",
            params: CommandParams(destination: "VEGA-2"),
            nextStep: FetchRun.Step.staging.rawValue
        ))
    }

    @Test func anAlreadyCompactedPayloadIsNotCompactedAgain() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .staging), world: world(payloadStatus: "compacted")
        ) == .dispatch(
            kind: .travel, deviceCode: "PLATE1",
            params: CommandParams(destination: "VEGA-2"),
            nextStep: FetchRun.Step.staging.rawValue
        ))
    }

    /// Both in flight: wait. `.wait` is the only action that does not re-stamp
    /// `stepStartedAt`, which is what lets a step deadline accumulate.
    @Test func waitsWhileBothAreUnderway() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .staging),
            world: world(payloadStatus: "compacting", openOperations: [
                "PAYLOAD1": busy("PAYLOAD1", kind: .compact, id: "OP1"),
                "PLATE1": busy("PLATE1", kind: .travel, id: "OP2"),
            ])
        ) == .wait)
    }

    @Test func advancesToAttachingWhenBothAreSettled() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .staging),
            world: world(payloadStatus: "compacted", plateLocation: "VEGA-2")
        ) == .advanceStep(nextStep: FetchRun.Step.attaching.rawValue))
    }

    /// The payload is mid-travel of its own. Advancing here would reach an
    /// attach the server refuses.
    @Test func doesNotAdvanceWhileThePayloadHasAnOpenOperation() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .staging),
            world: world(
                payloadStatus: "compacted", plateLocation: "VEGA-2",
                openOperations: ["PAYLOAD1": busy("PAYLOAD1", kind: .travel)]
            )
        ) == .wait)
    }
}

// MARK: - Attach, deliver, release

@Suite("FetchRun — the flight")
struct FetchRunFlightTests {
    private let run = FetchRun()

    private func world(
        plateLocation: String = "VEGA-2",
        payloadLocation: String? = "VEGA-2",
        attachedTo: String? = nil,
        payloadUpdatedAt: Date = Date(timeIntervalSince1970: 1_100),
        now: Date = fetchNow
    ) -> WorldSnapshot {
        fetchWorld(
            [
                plateFixture(location: plateLocation),
                payloadFixture(
                    location: payloadLocation, status: "compacted",
                    attachedTo: attachedTo, updatedAt: payloadUpdatedAt
                ),
            ],
            now: now
        )
    }

    @Test func ordersTheAttachOnThePlate() {
        #expect(run.nextAction(directive: fetchRunFixture(step: .attaching), world: world())
            == .dispatch(
                kind: .attach, deviceCode: "PLATE1",
                params: CommandParams(devices: ["PAYLOAD1"]),
                nextStep: FetchRun.Step.confirmingAttach.rawValue
            ))
    }

    @Test func attachAdvancesWhenThePayloadIsAlreadyOnTheGrid() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .attaching), world: world(attachedTo: "PLATE1")
        ) == .advanceStep(nextStep: FetchRun.Step.delivering.rawValue))
    }

    @Test func confirmAdvancesOnAnAttachedRow() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .confirmingAttach), world: world(attachedTo: "PLATE1")
        ) == .advanceStep(nextStep: FetchRun.Step.delivering.rawValue))
    }

    @Test func fliesThePlateToTheDestination() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .delivering),
            world: world(payloadLocation: nil, attachedTo: "PLATE1")
        ) == .dispatch(
            kind: .travel, deviceCode: "PLATE1",
            params: CommandParams(destination: "SOL-3"),
            nextStep: FetchRun.Step.delivering.rawValue
        ))
    }

    @Test func advancesToDetachingOnArrival() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .delivering),
            world: world(plateLocation: "SOL-3", payloadLocation: nil, attachedTo: "PLATE1")
        ) == .advanceStep(nextStep: FetchRun.Step.detaching.rawValue))
    }

    @Test func ordersTheDetachOnThePlate() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .detaching),
            world: world(plateLocation: "SOL-3", payloadLocation: nil, attachedTo: "PLATE1")
        ) == .dispatch(
            kind: .detach, deviceCode: "PLATE1",
            params: CommandParams(devices: ["PAYLOAD1"]),
            nextStep: FetchRun.Step.confirmingDetach.rawValue
        ))
    }

    /// Loose AND at the destination. A detach that landed somewhere unexpected
    /// has put the device in the wrong place, and calling that a delivery
    /// would hide it.
    @Test func releasesThePayloadWhenItIsLooseAtTheDestination() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .confirmingDetach),
            world: world(plateLocation: "SOL-3", payloadLocation: "SOL-3")
        ) == .releasePayload(nextStep: FetchRun.Step.homing.rawValue))
    }

    @Test func doesNotReleaseALoosePayloadStandingSomewhereElse() {
        #expect(run.nextAction(
            directive: fetchRunFixture(step: .confirmingDetach),
            world: world(plateLocation: "RIGEL-1", payloadLocation: "RIGEL-1")
        ) != .releasePayload(nextStep: FetchRun.Step.homing.rawValue))
    }
}

// MARK: - Homing

@Suite("FetchRun — homing")
struct FetchRunHomingTests {
    private let run = FetchRun()

    private func homing() -> Directive {
        var directive = fetchRunFixture(step: .homing, payload: nil)
        directive.theatreDepot = "RIGEL-1"
        return directive
    }

    /// The theatre is resolved from where the payload was DROPPED, not from
    /// the row's launch stamp. The destination is SOL-3; VEGA is 10 from SOL
    /// and RIGEL is 100.
    @Test func fliesThePlateToTheTheatreNearestTheDestination() {
        let world = fetchWorld(
            [plateFixture(location: "SOL-3")],
            theatres: [
                fetchTheatre("VEGA-1", system: "VEGA"), fetchTheatre("RIGEL-1", system: "RIGEL"),
            ]
        )
        #expect(run.nextAction(directive: homing(), world: world) == .dispatch(
            kind: .travel, deviceCode: "PLATE1",
            params: CommandParams(destination: "VEGA-1"),
            nextStep: FetchRun.Step.homing.rawValue
        ))
    }

    @Test func finishesOnceThePlateIsParked() {
        let world = fetchWorld(
            [plateFixture(location: "VEGA-1")], theatres: [fetchTheatre("VEGA-1", system: "VEGA")]
        )
        #expect(run.nextAction(directive: homing(), world: world) == .done)
    }

    /// Nowhere to park. The run's own job is complete and the plate is idle at
    /// the destination, so finishing is honest and stalling would be noise.
    @Test func finishesWhenNoOperationalTheatreResolves() {
        let world = fetchWorld([plateFixture(location: "SOL-3")], theatres: [])
        #expect(run.nextAction(directive: homing(), world: world) == .done)
    }
}
