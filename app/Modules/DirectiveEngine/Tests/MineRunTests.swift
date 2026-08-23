//
//  MineRunTests.swift
//  Replicould — DirectiveEngine
//
//  `MineRun` as a verdict table: preflight, the attach loop, the ferry, and
//  the detach at the belt.
//

import ConcurrencyExtras
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let hubLocation = "AINALRAM-3"
private let targetBelt = "TOSLIT-4-BELT-1"
/// Shares a system with `HaulRun.deliveryLocation` — the shape an entry-point
/// depot frees up as a same-system candidate.
private let sameSystemBelt = "AINALRAM-9-BELT-1"
private let carrierCode = "SC1"

/// One AMI directive as a device row carries it.
private typealias InForce = (name: String, status: String, config: [String: JSONValue])

private func mineRow(
    _ code: String, type: String, tags: [String] = [], location: String? = nil,
    status: String = "idle", attachedTo: String? = nil, controlledBy: String? = nil,
    directive: InForce? = nil, commands: [String] = [], features: [String] = [],
    updatedAt: Date = now
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let directive {
        detail["ami_directive"] = .object([
            "name": .string(directive.name), "config": .object(directive.config),
        ])
        detail["ami_directive_status"] = .string(directive.status)
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: controlledBy,
        attachedToDeviceCode: attachedTo, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: features, tags: tags, detail: .object(detail),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// The nine carried members, coded in recipe order so the lowest code is also
/// the first row the attach loop reaches. `attached` names how many of them
/// already ride the carrier.
private func carriedFleet(
    attached: Int = 0,
    location: String? = hubLocation,
    updatedAt: Date = now,
    omitting: String? = nil
) -> [Device] {
    var out: [Device] = []
    var n = 0
    for (type, quantity) in MineRecipe.carried {
        for _ in 0..<quantity {
            n += 1
            guard type != omitting else { continue }
            out.append(mineRow(
                "M\(String(format: "%02d", n))", type: type, tags: [MineRecipe.fleetTag.string],
                location: location, attachedTo: n <= attached ? carrierCode : nil,
                updatedAt: updatedAt
            ))
        }
    }
    return out
}

private func mineCarrier(location: String? = hubLocation, updatedAt: Date = now) -> Device {
    mineRow(
        carrierCode, type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag.string],
        location: location, updatedAt: updatedAt
    )
}

/// A live relay standing in the belt's system — what makes the belt commandable
/// at all, and so what `preflight` reads through `SalvageTargetPlanner`.
private let beltRelay = mineRow(
    "RLY1", type: "ftl_relay", location: "TOSLIT-1", status: "relaying", features: ["relay"]
)

/// A tagged mining controller already standing at the belt: the mine this run
/// exists to install is installed.
private let installedMine = mineRow(
    "X01", type: "ami_mining_controller", tags: [MineRecipe.fleetTag.string], location: targetBelt
)

// MARK: Adopt-and-arm fixtures

private let transportCode = "TC1"
private let freighterCode = "FR1"
private let memberCodes = (1...9).map { "M\(String(format: "%02d", $0))" }

/// Which controller each carried drone answers to once the adopt half has run.
private let adoptedByController = [
    "M02": "M01", "M03": "M01", "M04": "M01", "M06": "M05", "M07": "M05",
]

/// The nine carried members standing loose at the belt, as `confirmingDetach`
/// leaves them. `adoptedBy` and `armed` are keyed by member code.
private func beltFleet(
    at location: String = targetBelt,
    adoptedBy: [String: String] = [:],
    armed: [String: InForce] = [:],
    updatedAt: Date = now
) -> [Device] {
    var out: [Device] = []
    var n = 0
    for (type, quantity) in MineRecipe.carried {
        for _ in 0..<quantity {
            n += 1
            let code = memberCodes[n - 1]
            out.append(mineRow(
                code, type: type, tags: [MineRecipe.fleetTag.string], location: location,
                controlledBy: adoptedBy[code], directive: armed[code], updatedAt: updatedAt
            ))
        }
    }
    return out
}

/// The two self-moving members, standing at the delivery sink where they are
/// printed and where the freighter unloads.
private func transportPair(
    adopted: Bool = false,
    directive: String = HaulTargetPlanner.ferry,
    ferry: (collect: String, deliver: String, status: String)? = nil,
    at location: String = HaulRun.deliveryLocation,
    updatedAt: Date = now
) -> [Device] {
    [
        mineRow(
            transportCode, type: "ami_transport_controller", tags: [MineRecipe.fleetTag.string],
            location: location,
            directive: ferry.map {
                (
                    name: directive, status: $0.status,
                    config: ["collect": .string($0.collect), "deliver": .string($0.deliver)]
                )
            },
            updatedAt: updatedAt
        ),
        mineRow(
            freighterCode, type: "cargo_freighter", tags: [MineRecipe.fleetTag.string],
            location: location, controlledBy: adopted ? transportCode : nil,
            updatedAt: updatedAt
        ),
    ]
}

/// The four carried arm targets in force and running.
private let armedCarried: [String: InForce] = [
    "M01": (name: "gather_evenly", status: "active", config: [:]),
    "M05": (name: "belt_search", status: "active", config: [:]),
    "M08": (name: "service", status: "active", config: [:]),
    "M09": (name: "service", status: "active", config: [:]),
]

/// `rounds` completed trips round a dispatch/confirm loop, as the timeline
/// records them.
private func loopLog(_ dispatch: String, _ confirm: String, rounds: Int) -> [DirectiveLogEntry] {
    var out: [DirectiveLogEntry] = []
    for i in 0..<rounds {
        let base = now.addingTimeInterval(Double(i - rounds) * 10)
        out.append(logEntry(dispatch, at: base))
        out.append(logEntry(confirm, at: base.addingTimeInterval(1)))
    }
    return out
}

/// One arm round per entry, as the executor records it: the two step stamps
/// plus the command entry, typed columns and all.
private func armLog(_ sent: [(kind: OperationKind, deviceCode: String)]) -> [DirectiveLogEntry] {
    var out: [DirectiveLogEntry] = []
    for (i, command) in sent.enumerated() {
        let base = now.addingTimeInterval(Double(i - sent.count) * 10)
        out.append(logEntry(MineRun.Step.arming.rawValue, at: base))
        out.append(logEntry(MineRun.Step.confirmingArm.rawValue, at: base.addingTimeInterval(1)))
        out.append(DirectiveLogEntry(
            id: "C-\(i)", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
            summary: "Dispatched \(command.kind.rawValue) to \(command.deviceCode)",
            step: MineRun.Step.confirmingArm.rawValue, operationID: nil, eventID: nil,
            occurredAt: base.addingTimeInterval(1),
            commandKind: command.kind.rawValue, targetDeviceCode: command.deviceCode
        ))
    }
    return out
}

/// What a stall and its resolution leave on the timeline: neither a step stamp
/// nor a command, both stamped with the step the run is held on.
private func markerEntry(
    _ kind: DirectiveLogKind, on step: String, at occurredAt: Date
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "K-\(kind.rawValue)", directiveID: "D1", deviceCode: nil, kind: kind,
        summary: kind.rawValue, step: step, operationID: nil,
        eventID: nil, occurredAt: occurredAt
    )
}

/// A legacy dispatch entry — no typed columns — whose summary does not read as
/// one either, so neither the columns nor the fallback name an order.
private let unnamedDispatch = DirectiveLogEntry(
    id: "C-X", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
    summary: "sent something somewhere", step: MineRun.Step.confirmingArm.rawValue,
    operationID: nil, eventID: nil, occurredAt: now.addingTimeInterval(-5)
)

/// The four carried targets taken in one clean `set_directive` each.
private let cleanCarriedRounds: [(kind: OperationKind, deviceCode: String)] = [
    (.setDirective, "M01"), (.setDirective, "M05"),
    (.setDirective, "M08"), (.setDirective, "M09"),
]

/// A second free transport pair standing at the shared sink — every mine's
/// spares accumulate there under the same fleet tag.
private func sparePair(freighter: Bool = true) -> [Device] {
    var out = [mineRow(
        "TC2", type: "ami_transport_controller", tags: [MineRecipe.fleetTag.string],
        location: HaulRun.deliveryLocation
    )]
    if freighter {
        out.append(mineRow(
            "FR2", type: "cargo_freighter", tags: [MineRecipe.fleetTag.string],
            location: HaulRun.deliveryLocation
        ))
    }
    return out
}

/// A print-capable device at a meshed location the census shows holding stock —
/// what makes `HaulRun.deliverySink` resolve to something other than its fallback.
private let printHub = mineRow(
    "HUB1", type: "autofactory", location: hubLocation, commands: ["enqueue_print"]
)

private let hubRelay = mineRow(
    "RLY2", type: "ftl_relay", location: hubLocation, status: "relaying", features: ["relay"]
)

/// Theatres derived the same way `WorldSnapshot.read` does — off `devices` and
/// `footprints` alone, each meshed system its own component — so a fixture
/// stocking a printer resolves a theatre exactly as production would.
private func theatres(devices: [Device], footprints: [String: LocationFootprint]) -> [Theatre] {
    let mesh = SalvageTargetPlanner.meshSystems(in: devices)
    let components = Dictionary(uniqueKeysWithValues: mesh.map { ($0, $0) })
    return TheatreRegistry.recognise(
        devices: devices, pins: [], records: [], meshSystems: mesh,
        components: components, stockByLocation: footprints.mapValues(\.resources)
    )
}

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    log: [DirectiveLogEntry] = [],
    dispatchedOperations: [String: GameModels.Operation] = [:],
    footprints: [LocationFootprint] = []
) -> WorldSnapshot {
    let footprintsByLocation = Dictionary(footprints.map { ($0.location, $0) }, uniquingKeysWith: { _, last in last })
    return WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: log, dispatchedOperations: dispatchedOperations,
        footprints: footprintsByLocation,
        theatres: theatres(devices: devices, footprints: footprintsByLocation),
        now: now
    )
}

/// `theatreDepot` defaults to the file's canonical hub so a fixture that
/// recognises one there resolves it without every call site stamping it.
private func mineRunRow(
    step: String = MineRun.Step.preflight.rawValue,
    targets: [String] = [targetBelt],
    stepStartedAt: Date = now.addingTimeInterval(-60),
    deviceCode: String = carrierCode,
    theatreDepot: String? = hubLocation,
    returnToOrigin: Bool = false,
    controllerCode: String? = nil
) -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: deviceCode,
        controllerCode: controllerCode, roamCentre: nil, fleetTag: MineRecipe.fleetTag.string, sourceRelayCode: nil,
        targets: targets, targetIndex: 0, step: step, stepStartedAt: stepStartedAt,
        returnToOrigin: returnToOrigin, originDesignation: nil, attentionReason: nil,
        createdAt: now.addingTimeInterval(-600), updatedAt: now, theatreDepot: theatreDepot
    )
}

/// The census reading that makes `hubLocation` resolve at all: the hub holds
/// stock. Without it a print-capable device is not yet a hub.
private let hubStock = LocationFootprint(
    location: hubLocation, devices: 0, resources: 5_000, resourceSites: 0,
    locationEvents: 0, replicants: 0, fetchedAt: now
)

private func logEntry(_ step: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "S-\(step)-\(occurredAt.timeIntervalSince1970)", directiveID: "D1",
        deviceCode: nil, kind: .stepStarted, summary: "Step: \(step)", step: step,
        operationID: nil, eventID: nil, occurredAt: occurredAt
    )
}

/// `rounds` completed trips round the attach loop, as the timeline records
/// them — the only evidence a confirm step has that its own order landed.
private func attachLog(rounds: Int) -> [DirectiveLogEntry] {
    var out: [DirectiveLogEntry] = []
    for i in 0..<rounds {
        let base = now.addingTimeInterval(Double(i - rounds) * 10)
        out.append(logEntry(MineRun.Step.attaching.rawValue, at: base))
        out.append(logEntry(MineRun.Step.confirmingAttach.rawValue, at: base.addingTimeInterval(1)))
    }
    return out
}

/// The travel op that closed 139 ms ago, the shape `travelPositionUnconfirmed`
/// reads as the arrival watermark.
private func closedTravel(entityCode: String = carrierCode) -> [String: GameModels.Operation] {
    let op = GameModels.Operation(
        id: "OP-T", entityCode: entityCode, kind: OperationKind.travel.rawValue,
        status: .completed, source: .event, startedAt: now.addingTimeInterval(-300),
        completesAt: nil, lastConfirmedAt: now.addingTimeInterval(-0.139), detail: .object([:])
    )
    return [op.id: op]
}

private func openTravel(on entity: String = carrierCode) -> [String: GameModels.Operation] {
    [entity: GameModels.Operation(
        id: "OP-1", entityCode: entity, kind: OperationKind.travel.rawValue, status: .active,
        source: .poll, startedAt: now.addingTimeInterval(-60), completesAt: nil,
        lastConfirmedAt: now, detail: .object([:])
    )]
}

// MARK: - Tests

@Suite("MineRun — ferrying a mine fleet to its belt")
struct MineRunTests {

    // MARK: Registration

    @Test("the engine runs mineRun rows through this machine")
    func isRegistered() {
        #expect(MissionRegistry.machine(for: .mineRun) is MineRun)
        #expect(MissionRegistry.firstStep(for: .mineRun) == MineRun.Step.preflight.rawValue)
    }

    @Test func stepVocabularyIsFrozen() {
        #expect(MineRun.Step.allCases.map(\.rawValue) == [
            "preflight", "attaching", "confirmingAttach", "travelling", "confirmingArrival",
            "detaching", "confirmingDetach", "adopting", "confirmingAdopt", "arming",
            "confirmingArm", "returning",
        ])
    }

    /// The run delivers one fleet to one belt; it plans no targets of its own.
    @Test("the run never roams")
    func planIsExhausted() {
        let context = RoamContext(
            centre: nil, vessel: nil, stars: [], assays: [], devices: [], attempted: []
        )
        #expect(MineRun().plan(context) == .exhausted)
    }

    // MARK: Membership

    /// The choice must not move as attachment proceeds: an attached row leaves
    /// the free pool, so counting attached rows first is what keeps the same
    /// nine devices selected on every evaluation.
    @Test("membership is the same nine part-way through the attach loop")
    func membershipIsStableWhileAttaching() {
        let cold = world(devices: carriedFleet() + [mineCarrier()])
        let midway = world(devices: carriedFleet(attached: 4) + [mineCarrier()])

        let before = MineRun.members(of: mineRunRow(), in: cold).values.flatMap { $0.map(\.deviceCode) }
        let after = MineRun.members(of: mineRunRow(), in: midway).values.flatMap { $0.map(\.deviceCode) }

        #expect(Set(before) == Set(after))
        #expect(before.count == 9)
    }

    // MARK: Preflight

    /// The carrier this row names has left the fleet; substituting another
    /// would be a fabrication.
    @Test("a missing carrier stalls")
    func missingCarrierStalls() {
        let snapshot = world(devices: carriedFleet() + [beltRelay])

        #expect(MineRun().nextAction(directive: mineRunRow(), world: snapshot)
                == .stall(.unreachableDevice))
    }

    /// A row born with no belt is malformed — there is nowhere to ferry to.
    @Test("no target belt stalls")
    func missingTargetStalls() {
        let snapshot = world(devices: carriedFleet() + [mineCarrier(), beltRelay])

        #expect(MineRun().nextAction(directive: mineRunRow(targets: []), world: snapshot)
                == .stall(.unreachableDevice))
    }

    /// A belt outside the mesh cannot be commanded at all, whatever the fleet
    /// looks like — and `.mineFleetIncomplete` is reserved for fleet gaps.
    @Test("a de-meshed belt stalls rather than blaming the fleet")
    func deMeshedBeltStalls() {
        let snapshot = world(devices: carriedFleet() + [mineCarrier()])

        #expect(MineRun().nextAction(directive: mineRunRow(), world: snapshot)
                == .stall(.unreachableDevice))
    }

    /// A negative finding over local rows: buy one authoritative tag read —
    /// the only scope that sees attached and stowed members — before escalating.
    @Test("a short fleet buys a tag read before escalating")
    func shortFleetRefreshesTheTag() {
        let snapshot = world(
            devices: carriedFleet(omitting: "mining_drone") + [mineCarrier(), beltRelay]
        )

        #expect(MineRun().nextAction(directive: mineRunRow(), world: snapshot)
                == .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete))
    }

    /// The goal is a mine standing at the belt. One already there means the row
    /// retires rather than spending the carrier on a second.
    @Test("a belt that already holds a mine is done")
    func installedBeltIsDone() {
        let snapshot = world(
            devices: carriedFleet() + [mineCarrier(), beltRelay, installedMine]
        )

        #expect(MineRun().nextAction(directive: mineRunRow(), world: snapshot) == .done)
    }

    /// A mine on the hub's own belt is invisible to `MineRecipe.installedBelts`,
    /// which filters `location != hub` — so a row aimed there is malformed.
    @Test("a target belt that is the hub's own location stalls")
    func theHubsOwnBeltStalls() {
        let hubOnTheBelt = mineRow(
            "HUB2", type: "autofactory", location: targetBelt, commands: ["enqueue_print"]
        )
        let snapshot = world(
            devices: carriedFleet() + [mineCarrier(), beltRelay, hubOnTheBelt],
            footprints: [LocationFootprint(
                location: targetBelt, devices: 0, resources: 5_000, resourceSites: 0,
                locationEvents: 0, replicants: 0, fetchedAt: now
            )]
        )

        let row = mineRunRow(theatreDepot: targetBelt)
        #expect(snapshot.theatreDepot(for: row) == targetBelt)
        #expect(MineRun().nextAction(directive: row, world: snapshot)
                == .stall(.unreachableDevice))
    }

    @Test("a staged fleet at a meshed belt starts attaching")
    func stagedFleetAdvances() {
        let snapshot = world(devices: carriedFleet() + [mineCarrier(), beltRelay])

        #expect(MineRun().nextAction(directive: mineRunRow(), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.attaching.rawValue))
    }

    // MARK: Attaching

    /// One at a time, lowest-coded first, and never naming its own step:
    /// `attach` is immediate, so no operation row could gate a re-dispatch.
    @Test("the first attach names the lowest-coded member")
    func attachDispatchesTheLowestCodedMember() {
        let snapshot = world(devices: carriedFleet() + [mineCarrier(), beltRelay])

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.attaching.rawValue), world: snapshot)
                == .dispatch(
                    kind: .attach, deviceCode: carrierCode,
                    params: CommandParams(devices: ["M01"]),
                    nextStep: MineRun.Step.confirmingAttach.rawValue
                )
        )
    }

    /// The pick is stable: four rows in, the run reaches for the fifth and
    /// keeps reaching for it until it lands.
    @Test("a part-attached fleet dispatches the next member, twice over")
    func attachChoiceIsStable() {
        let snapshot = world(devices: carriedFleet(attached: 4) + [mineCarrier(), beltRelay])
        let directive = mineRunRow(step: MineRun.Step.attaching.rawValue)

        let first = MineRun().nextAction(directive: directive, world: snapshot)
        let second = MineRun().nextAction(directive: directive, world: snapshot)

        #expect(first == .dispatch(
            kind: .attach, deviceCode: carrierCode, params: CommandParams(devices: ["M05"]),
            nextStep: MineRun.Step.confirmingAttach.rawValue
        ))
        #expect(first == second)
    }

    @Test("a fully attached fleet travels")
    func fullyAttachedFleetTravels() {
        let snapshot = world(devices: carriedFleet(attached: 9) + [mineCarrier(), beltRelay])

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.attaching.rawValue), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.travelling.rawValue))
    }

    /// Nothing left to attach is not a complete fleet. A short roster buys a tag
    /// read rather than flying an incomplete mine to the belt.
    @Test("a short fleet with nothing left to attach never flies")
    func shortFleetWithNothingLooseNeverTravels() {
        let snapshot = world(
            devices: carriedFleet(attached: 9, omitting: "mining_drone") + [mineCarrier(), beltRelay]
        )

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.attaching.rawValue), world: snapshot)
                == .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete))
    }

    // MARK: Confirming an attach

    /// The command's own confirm-read lands just BEFORE the step is stamped, so
    /// the round count is what proves the ordered attach landed.
    @Test("an attach that landed goes back for the next member")
    func landedAttachLoops() {
        let snapshot = world(
            devices: carriedFleet(attached: 1) + [mineCarrier(), beltRelay],
            log: attachLog(rounds: 1)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAttach.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.attaching.rawValue)
        )
    }

    /// Nothing in a mission loop refreshes device rows, so a row predating the
    /// order cannot say whether it landed. Buy the read, on a throttle.
    @Test("a row unread since the order buys one read")
    func staleRowBuysARead() {
        let snapshot = world(
            devices: carriedFleet(updatedAt: now.addingTimeInterval(-300))
                + [mineCarrier(), beltRelay],
            log: attachLog(rounds: 1)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAttach.rawValue), world: snapshot
            ) == .refreshDevices(deviceCodes: ["M01"], thenStall: nil)
        )
    }

    /// The deadline is read BEFORE the staleness guard: a read that keeps
    /// failing never advances `updatedAt`, so the other order loops forever.
    @Test("past the deadline the run spends one last read and surfaces")
    func deadlineOutranksStaleness() {
        let snapshot = world(
            devices: carriedFleet(updatedAt: now.addingTimeInterval(-900))
                + [mineCarrier(), beltRelay],
            log: attachLog(rounds: 1)
        )
        let directive = mineRunRow(
            step: MineRun.Step.confirmingAttach.rawValue,
            stepStartedAt: now.addingTimeInterval(-(MineRun.attachConfirmDeadline + 60))
        )

        #expect(MineRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["M01"], thenStall: .commandRejected))
    }

    /// **The shape production actually produces.** The command's own `.high`
    /// read of the moved row lands BEFORE the executor stamps the step, so the
    /// row that proves the attach landed is correct and stale at once.
    @Test func aStaleButAttachedMemberStillCountsAsProgress() {
        let snapshot = world(
            devices: carriedFleet(attached: 1, updatedAt: now.addingTimeInterval(-61))
                + [mineCarrier(), beltRelay],
            log: attachLog(rounds: 1)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAttach.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.attaching.rawValue)
        )
    }

    /// Two rounds ordered and one row aboard: the SECOND attach has not landed,
    /// so the ladder holds the loop rather than ordering a third.
    @Test func aSecondAttachStillOutstandingEngagesTheLadder() {
        let fresh = world(
            devices: carriedFleet(attached: 1) + [mineCarrier(), beltRelay],
            log: attachLog(rounds: 2)
        )
        let unread = world(
            devices: carriedFleet(attached: 1, updatedAt: now.addingTimeInterval(-300))
                + [mineCarrier(), beltRelay],
            log: attachLog(rounds: 2)
        )
        let directive = mineRunRow(step: MineRun.Step.confirmingAttach.rawValue)

        #expect(MineRun().nextAction(directive: directive, world: fresh) == .wait)
        #expect(MineRun().nextAction(directive: directive, world: unread)
                == .refreshDevices(deviceCodes: ["M02"], thenStall: nil))
    }

    /// A fresh row that still shows the member loose is the attach failing, not
    /// a stale read — hold for the deadline rather than re-ordering blindly.
    @Test("a fresh but unattached member waits out the deadline")
    func freshUnattachedWaits() {
        let snapshot = world(
            devices: carriedFleet(updatedAt: now.addingTimeInterval(-10))
                + [mineCarrier(), beltRelay],
            log: attachLog(rounds: 1)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAttach.rawValue), world: snapshot
            ) == .wait
        )
    }

    // MARK: Travelling

    @Test("the loaded carrier is flown to the belt")
    func travelDispatches() {
        let snapshot = world(devices: carriedFleet(attached: 9) + [mineCarrier(), beltRelay])

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.travelling.rawValue), world: snapshot)
                == .dispatch(
                    kind: .travel, deviceCode: carrierCode,
                    params: CommandParams(destination: targetBelt),
                    nextStep: MineRun.Step.confirmingArrival.rawValue
                )
        )
    }

    /// An arrival settles in two transactions — the op closes first, the
    /// location is written second — so a tick in the gap must not re-command
    /// travel at an already-parked carrier.
    @Test("an unresolved arrival watermark defers the dispatch")
    func travelWaitsOnTheArrivalWatermark() {
        let lagging = mineCarrier(updatedAt: now.addingTimeInterval(-5.139))
        let snapshot = world(
            devices: carriedFleet(attached: 9) + [lagging, beltRelay],
            dispatchedOperations: closedTravel()
        )

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.travelling.rawValue), world: snapshot)
                == .wait)
    }

    /// The gate sits after the location check, so a carrier already standing at
    /// the belt unloads instead of being re-commanded there.
    @Test("a carrier already at the belt goes straight to detaching")
    func travelAtTheBeltAdvances() {
        let snapshot = world(
            devices: carriedFleet(attached: 9, location: targetBelt)
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.travelling.rawValue), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.detaching.rawValue))
    }

    // MARK: Confirming the arrival

    @Test("a fresh carrier at the belt unloads")
    func arrivalConfirmed() {
        let snapshot = world(
            devices: carriedFleet(attached: 9, location: targetBelt)
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArrival.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.detaching.rawValue)
        )
    }

    /// The trip is still under way; nothing to judge yet.
    @Test("an open travel op holds the confirmation")
    func openTravelWaits() {
        let snapshot = world(
            devices: carriedFleet(attached: 9, updatedAt: now.addingTimeInterval(-600))
                + [mineCarrier(updatedAt: now.addingTimeInterval(-600)), beltRelay],
            openOperations: openTravel()
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArrival.rawValue), world: snapshot
            ) == .wait
        )
    }

    // MARK: Detaching

    /// One command for the whole fleet: `detach` takes the codes as an array,
    /// so nine rows come off in a single round trip.
    @Test("the whole fleet comes off in one detach")
    func detachNamesEveryAttachedMember() {
        let snapshot = world(
            devices: carriedFleet(attached: 9, location: targetBelt)
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.detaching.rawValue), world: snapshot)
                == .dispatch(
                    kind: .detach, deviceCode: carrierCode,
                    params: CommandParams(devices: (1...9).map { "M\(String(format: "%02d", $0))" }),
                    nextStep: MineRun.Step.confirmingDetach.rawValue
                )
        )
    }

    /// Re-entered with nothing left aboard — a resumed row, a hand-detach — the
    /// step still has to move the run on rather than sit on an empty grid.
    @Test("a grid already empty hands straight over to adoption")
    func detachWithNothingAboardAdvances() {
        let snapshot = world(
            devices: carriedFleet(location: targetBelt)
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.detaching.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.adopting.rawValue)
        )
    }

    // MARK: Confirming the detach

    @Test("nine fresh rows loose at the belt hand over to adoption")
    func detachConfirmed() {
        let snapshot = world(
            devices: carriedFleet(location: targetBelt) + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingDetach.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.adopting.rawValue)
        )
    }

    /// Rows unread since the detach was ordered cannot report it landing.
    @Test("rows unread since the detach buy one read")
    func detachStaleRowsBuyARead() {
        let snapshot = world(
            devices: carriedFleet(attached: 9, location: targetBelt, updatedAt: now.addingTimeInterval(-300))
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        let action = MineRun().nextAction(
            directive: mineRunRow(step: MineRun.Step.confirmingDetach.rawValue), world: snapshot
        )
        guard case let .refreshDevices(codes, thenStall) = action else {
            Issue.record("expected a device read, got \(action)")
            return
        }
        #expect(Set(codes) == Set((1...9).map { "M\(String(format: "%02d", $0))" }))
        #expect(thenStall == nil)
    }

    /// Each conjunct of the landing test alone. Varying one at a time is what
    /// `detachConfirmed` and `detachStaleRowsBuyARead` cannot do between them.
    @Test("a member still on the carrier is not landed")
    func detachAttachedMemberIsNotLanded() {
        let snapshot = world(
            devices: carriedFleet(attached: 9, location: targetBelt)
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingDetach.rawValue), world: snapshot
            ) == .wait
        )
    }

    @Test("a member loose somewhere other than the belt is not landed")
    func detachAwayFromTheBeltIsNotLanded() {
        let snapshot = world(
            devices: carriedFleet(location: hubLocation) + [mineCarrier(), beltRelay]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingDetach.rawValue), world: snapshot
            ) == .wait
        )
    }

    @Test("a member loose at the belt on an unread row is not landed")
    func detachStaleLooseMemberIsNotLanded() {
        let snapshot = world(
            devices: carriedFleet(location: targetBelt, updatedAt: now.addingTimeInterval(-300))
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        let action = MineRun().nextAction(
            directive: mineRunRow(step: MineRun.Step.confirmingDetach.rawValue), world: snapshot
        )
        guard case let .refreshDevices(codes, thenStall) = action else {
            Issue.record("expected a device read, got \(action)")
            return
        }
        #expect(Set(codes) == Set((1...9).map { "M\(String(format: "%02d", $0))" }))
        #expect(thenStall == nil)
    }

    // MARK: Adopting

    /// `adopt` takes a device list, so one command hands the whole trio over.
    @Test("the mining controller adopts all three drones in one command")
    func adoptNamesEveryUnadoptedMiningDrone() {
        let snapshot = world(
            devices: beltFleet() + transportPair() + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting.rawValue), world: snapshot)
                == .dispatch(
                    kind: .adopt, deviceCode: "M01",
                    params: CommandParams(devices: ["M02", "M03", "M04"]),
                    nextStep: MineRun.Step.confirmingAdopt.rawValue
                )
        )
    }

    @Test("the survey pair is adopted once the mining trio is")
    func adoptTakesTheSurveyPairSecond() {
        let snapshot = world(
            devices: beltFleet(adoptedBy: ["M02": "M01", "M03": "M01", "M04": "M01"])
                + transportPair() + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting.rawValue), world: snapshot)
                == .dispatch(
                    kind: .adopt, deviceCode: "M05",
                    params: CommandParams(devices: ["M06", "M07"]),
                    nextStep: MineRun.Step.confirmingAdopt.rawValue
                )
        )
    }

    /// Two free pairs stand at the shared sink. Without a lease the run takes
    /// the lowest code; the launch's stamp is what points it at the other one.
    @Test("the leased transport controller wins over a lower-coded free row")
    func transportHonoursTheLease() {
        let snapshot = world(
            devices: beltFleet(adoptedBy: adoptedByController) + transportPair() + sparePair()
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(MineRun.transport(of: mineRunRow(), in: snapshot)?.controller.deviceCode == transportCode)
        #expect(
            MineRun.transport(of: mineRunRow(controllerCode: "TC2"), in: snapshot)?
                .controller.deviceCode == "TC2"
        )
    }

    /// A lease some other hand armed elsewhere is not this run's to overwrite,
    /// so resolution falls through rather than commandeering the row.
    @Test("a leased controller ferrying another belt falls back to open resolution")
    func aHijackedLeaseFallsBack() {
        let hijacked = mineRow(
            "TC2", type: MineRecipe.transportDeviceType, tags: [MineRecipe.fleetTag.string],
            location: HaulRun.deliveryLocation,
            directive: (
                name: HaulTargetPlanner.ferry, status: "active",
                config: ["collect": .string("VEGA-BELT-9"), "deliver": .string(HaulRun.deliveryLocation)]
            )
        )
        let snapshot = world(
            devices: beltFleet(adoptedBy: adoptedByController) + transportPair() + [hijacked]
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun.transport(of: mineRunRow(controllerCode: "TC2"), in: snapshot)?
                .controller.deviceCode == transportCode
        )
    }

    /// The run's own arming leaves the lease collecting this belt, so a
    /// re-evaluation after arm still reaches for the row it leased — even with
    /// a lower-coded row the open resolution would otherwise prefer.
    @Test("a leased controller already ferrying this belt is still the lease")
    func anArmedLeaseIsStillHonoured() {
        let ferrying = { (code: String) in
            mineRow(
                code, type: MineRecipe.transportDeviceType, tags: [MineRecipe.fleetTag.string],
                location: HaulRun.deliveryLocation,
                directive: (
                    name: HaulTargetPlanner.ferry, status: "active",
                    config: [
                        "collect": .string(targetBelt),
                        "deliver": .string(HaulRun.deliveryLocation),
                    ]
                )
            )
        }
        let freeFreighter = mineRow(
            freighterCode, type: "cargo_freighter", tags: [MineRecipe.fleetTag.string],
            location: HaulRun.deliveryLocation
        )
        let snapshot = world(
            devices: beltFleet(adoptedBy: adoptedByController)
                + [ferrying(transportCode), ferrying("TC2"), freeFreighter]
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun.transport(of: mineRunRow(), in: snapshot)?.controller.deviceCode == transportCode
        )
        #expect(
            MineRun.transport(of: mineRunRow(controllerCode: "TC2"), in: snapshot)?
                .controller.deviceCode == "TC2"
        )
    }

    /// The transport pair stands at the delivery sink, not the belt, and is
    /// resolved through `MineRecipe.unassignedFleet` there.
    @Test("the freighter is adopted last")
    func adoptTakesTheFreighterLast() {
        let snapshot = world(
            devices: beltFleet(adoptedBy: adoptedByController) + transportPair()
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting.rawValue), world: snapshot)
                == .dispatch(
                    kind: .adopt, deviceCode: transportCode,
                    params: CommandParams(devices: [freighterCode]),
                    nextStep: MineRun.Step.confirmingAdopt.rawValue
                )
        )
    }

    @Test("a fully adopted fleet arms")
    func adoptedFleetArms() {
        let snapshot = world(
            devices: beltFleet(adoptedBy: adoptedByController) + transportPair(adopted: true)
                + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting.rawValue), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.arming.rawValue)
        )
    }

    /// Adoption cannot proceed against a fleet the local rows cannot even
    /// assemble — buy the one scope that sees every tagged member first.
    @Test("a missing transport pair buys a tag read")
    func adoptWithoutTransportRefreshesTheTag() {
        let snapshot = world(
            devices: beltFleet() + [mineCarrier(location: targetBelt), beltRelay]
        )

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting.rawValue), world: snapshot)
                == .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
        )
    }

    // MARK: Confirming an adoption

    /// The command's own read of the adopted rows lands BEFORE the step is
    /// stamped, so the round count is what proves the adoption landed.
    @Test("an adoption that landed on a stale row still counts as progress")
    func landedAdoptionLoops() {
        let snapshot = world(
            devices: beltFleet(
                adoptedBy: ["M02": "M01", "M03": "M01", "M04": "M01"],
                updatedAt: now.addingTimeInterval(-61)
            ) + transportPair() + [mineCarrier(location: targetBelt), beltRelay],
            log: loopLog(MineRun.Step.adopting.rawValue, MineRun.Step.confirmingAdopt.rawValue, rounds: 1)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAdopt.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.adopting.rawValue)
        )
    }

    /// Two rounds ordered and one adoption held: the SECOND has not landed, so
    /// the ladder holds the loop and names the survey pair.
    @Test("a second adoption still outstanding engages the ladder")
    func secondAdoptionEngagesTheLadder() {
        let snapshot = world(
            devices: beltFleet(
                adoptedBy: ["M02": "M01", "M03": "M01", "M04": "M01"],
                updatedAt: now.addingTimeInterval(-300)
            ) + transportPair() + [mineCarrier(location: targetBelt), beltRelay],
            log: loopLog(MineRun.Step.adopting.rawValue, MineRun.Step.confirmingAdopt.rawValue, rounds: 2)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAdopt.rawValue), world: snapshot
            ) == .refreshDevices(deviceCodes: ["M06", "M07"], thenStall: nil)
        )
    }

    /// The adopt loop's counter reaches zero across a `.resolved` entry, so a
    /// retried stall hands back to the step that can dispatch — the same
    /// recovery the arm loop needs its third case for.
    @Test("a retried adopt stall re-dispatches instead of re-stalling")
    func retriedAdoptStallReturnsToAdopting() {
        let snapshot = world(
            devices: beltFleet() + transportPair() + [mineCarrier(location: targetBelt), beltRelay],
            log: loopLog(MineRun.Step.adopting.rawValue, MineRun.Step.confirmingAdopt.rawValue, rounds: 1) + [
                markerEntry(.stalled, on: MineRun.Step.confirmingAdopt.rawValue, at: now.addingTimeInterval(-3)),
                markerEntry(.resolved, on: MineRun.Step.confirmingAdopt.rawValue, at: now.addingTimeInterval(-2)),
            ]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAdopt.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.adopting.rawValue)
        )
    }

    @Test("an adoption past its deadline spends one last read and surfaces")
    func adoptionDeadlineSurfaces() {
        let snapshot = world(
            devices: beltFleet(updatedAt: now.addingTimeInterval(-900)) + transportPair()
                + [mineCarrier(location: targetBelt), beltRelay],
            log: loopLog(MineRun.Step.adopting.rawValue, MineRun.Step.confirmingAdopt.rawValue, rounds: 1)
        )
        let directive = mineRunRow(
            step: MineRun.Step.confirmingAdopt.rawValue,
            stepStartedAt: now.addingTimeInterval(-(MineRun.attachConfirmDeadline + 60))
        )

        #expect(MineRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["M02", "M03", "M04"], thenStall: .commandRejected))
    }

    // MARK: Arming

    private func armedWorld(
        _ armed: [String: InForce],
        ferry: (collect: String, deliver: String, status: String)? = nil,
        log: [DirectiveLogEntry] = []
    ) -> WorldSnapshot {
        world(
            devices: beltFleet(adoptedBy: adoptedByController, armed: armed)
                + transportPair(adopted: true, ferry: ferry)
                + [mineCarrier(location: targetBelt), beltRelay],
            log: log
        )
    }

    @Test("nothing armed sets the mining controller's directive first")
    func armStartsWithTheMiningController() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: armedWorld([:])
            ) == .dispatch(
                kind: .setDirective, deviceCode: "M01",
                params: CommandParams(directive: "gather_evenly", configuration: nil),
                nextStep: MineRun.Step.confirmingArm.rawValue
            )
        )
    }

    /// Right directive, not running: `activate` is what starts it. Re-sending
    /// the name would never touch the status.
    @Test("a paused directive is activated, not re-sent")
    func armActivatesAPausedDirective() {
        let snapshot = armedWorld(["M01": (name: "gather_evenly", status: "paused", config: [:])])

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: snapshot)
                == .dispatch(
                    kind: OperationKind.simple("activate"), deviceCode: "M01",
                    params: CommandParams(), nextStep: MineRun.Step.confirmingArm.rawValue
                )
        )
    }

    @Test("four armed leaves the ferry, configured for this belt")
    func armDispatchesTheFerryLast() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: armedWorld(armedCarried)
            ) == .dispatch(
                kind: .setDirective, deviceCode: transportCode,
                params: CommandParams(
                    directive: HaulTargetPlanner.ferry,
                    configuration: [
                        "collect": .string(targetBelt),
                        "deliver": .string(HaulRun.deliveryLocation),
                    ]
                ),
                nextStep: MineRun.Step.confirmingArm.rawValue
            )
        )
    }

    @Test("all five in force and running finishes the run")
    func allFiveArmedIsDone() {
        let snapshot = armedWorld(
            armedCarried,
            ferry: (collect: targetBelt, deliver: HaulRun.deliveryLocation, status: "active")
        )

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: snapshot)
                == .done)
    }

    /// The sink is DERIVED, so a hub that flickers between dispatch and confirm
    /// must not read a landed ferry as refused.
    @Test("a ferry delivering to the fallback sink still reads as in force")
    func ferryToleratesTheFallbackSink() {
        let snapshot = world(
            devices: beltFleet(adoptedBy: adoptedByController, armed: armedCarried)
                + transportPair(
                    adopted: true,
                    ferry: (collect: targetBelt, deliver: HaulRun.deliveryLocation, status: "active"),
                    at: hubLocation
                )
                + [mineCarrier(location: targetBelt), beltRelay, printHub, hubRelay],
            footprints: [LocationFootprint(
                location: hubLocation, devices: 0, resources: 5_000, resourceSites: 0,
                locationEvents: 0, replicants: 0, fetchedAt: now
            )]
        )

        #expect(HaulRun.deliverySink(in: snapshot, for: mineRunRow()) == hubLocation)
        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: snapshot)
                == .done)
    }

    private func installedWorld(spare: [Device]) -> WorldSnapshot {
        world(
            devices: beltFleet(adoptedBy: adoptedByController, armed: armedCarried)
                + transportPair(
                    adopted: true,
                    ferry: (collect: targetBelt, deliver: HaulRun.deliveryLocation, status: "active")
                )
                + spare + [mineCarrier(location: targetBelt), beltRelay]
        )
    }

    /// The fleet tag and the delivery sink are shared by every mine, so spare
    /// free pairs stand where this run's installed one does.
    @Test("a spare free pair at the sink does not hijack the installed one")
    func spareTransportPairDoesNotHijack() throws {
        let snapshot = installedWorld(spare: sparePair())

        let pair = try #require(MineRun.transport(of: mineRunRow(), in: snapshot))
        #expect(pair.controller.deviceCode == transportCode)
        #expect(pair.freighter.deviceCode == freighterCode)
        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: snapshot)
                == .done)
    }

    /// A spare controller with no freighter beside it must not read as this
    /// fleet's transport half and fail the whole run for a gap it does not have.
    @Test("a lone spare controller does not fail an installed fleet")
    func spareControllerDoesNotStallAnInstalledFleet() {
        let snapshot = installedWorld(spare: sparePair(freighter: false))

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: snapshot)
                == .done)
        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting.rawValue), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.arming.rawValue)
        )
    }

    /// `gather_resources` mines one resource type and would strand the rest of
    /// the belt. It is unreachable because no builder here names it.
    @Test("no arm target ever names gather_resources")
    func armTargetsNeverNameGatherResources() throws {
        let snapshot = armedWorld([:])
        let targets = try #require(MineRun.armTargets(of: mineRunRow(), in: snapshot))

        #expect(targets.map(\.directive) == [
            "gather_evenly", "belt_search", "service", "service", HaulTargetPlanner.ferry,
        ])
        #expect(!targets.contains { $0.directive == "gather_resources" })
        #expect(targets.map(\.deviceCode) == ["M01", "M05", "M08", "M09", transportCode])
    }

    /// A belt sharing the depot's own system must arm `shuttle` — an
    /// entry-point depot frees exactly this candidate at distance 0.0, and a
    /// same-system `ferry` is malformed.
    @Test("the ferry arm target becomes shuttle for a same-system belt")
    func armTargetsChooseShuttleForASameSystemBelt() throws {
        let snapshot = world(
            devices: beltFleet(at: sameSystemBelt, adoptedBy: adoptedByController, armed: [:])
                + transportPair(adopted: true)
                + [mineCarrier(location: sameSystemBelt)]
        )
        let row = mineRunRow(targets: [sameSystemBelt])
        let targets = try #require(MineRun.armTargets(of: row, in: snapshot))
        let transport = try #require(targets.first { $0.deviceCode == transportCode })

        #expect(transport.directive == HaulTargetPlanner.shuttle)
        #expect(transport.configuration?["collect"]?.stringValue == sameSystemBelt)
        #expect(transport.configuration?["deliver"]?.stringValue == HaulRun.deliverySink(in: snapshot, for: row))
    }

    /// A `shuttle` already in force must finish the run rather than being
    /// re-armed with `ferry` every tick — the recorded same-step-dispatch
    /// failure shape.
    @Test("a shuttle already in force finishes the run")
    func shuttleInForceFinishesTheRun() {
        let snapshot = world(
            devices: beltFleet(at: sameSystemBelt, adoptedBy: adoptedByController, armed: armedCarried)
                + transportPair(
                    adopted: true, directive: HaulTargetPlanner.shuttle,
                    ferry: (collect: sameSystemBelt, deliver: HaulRun.deliveryLocation, status: "active")
                )
                + [mineCarrier(location: sameSystemBelt)]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.arming.rawValue, targets: [sameSystemBelt]), world: snapshot
            ) == .done
        )
    }

    // MARK: Confirming an arming

    @Test("every target in force and running goes back to arming")
    func confirmArmLoopsWhenAllFiveLanded() {
        let snapshot = armedWorld(
            armedCarried,
            ferry: (collect: targetBelt, deliver: HaulRun.deliveryLocation, status: "active"),
            log: armLog(cleanCarriedRounds + [(.setDirective, transportCode)])
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.arming.rawValue)
        )
    }

    /// One round ordered, one target armed on a row older than the step stamp:
    /// the round count is the only evidence the command landed.
    @Test("an arming that landed on a stale row still counts as progress")
    func landedArmingLoops() {
        let snapshot = world(
            devices: beltFleet(
                adoptedBy: adoptedByController,
                armed: ["M01": (name: "gather_evenly", status: "active", config: [:])],
                updatedAt: now.addingTimeInterval(-61)
            ) + transportPair(adopted: true, updatedAt: now.addingTimeInterval(-61))
                + [mineCarrier(location: targetBelt), beltRelay],
            log: armLog([(.setDirective, "M01")])
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.arming.rawValue)
        )
    }

    /// A `set_directive` that lands PAUSED has landed: only `arming` can order
    /// the `activate` that finishes it, so the confirm has to hand back.
    @Test("a set_directive that lands paused goes back to arming to activate")
    func pausedLandingReturnsToArming() {
        let snapshot = armedWorld(
            ["M01": (name: "gather_evenly", status: "paused", config: [:])],
            log: armLog([(.setDirective, "M01")])
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.arming.rawValue)
        )
        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming.rawValue), world: snapshot)
                == .dispatch(
                    kind: OperationKind.simple("activate"), deviceCode: "M01",
                    params: CommandParams(), nextStep: MineRun.Step.confirmingArm.rawValue
                )
        )
    }

    /// The activate has not landed: the directive is in force but still paused
    /// after the round that should have started it.
    @Test("an activate still outstanding engages the ladder")
    func outstandingActivateEngagesTheLadder() {
        let snapshot = armedWorld(
            ["M01": (name: "gather_evenly", status: "paused", config: [:])],
            log: armLog([(.setDirective, "M01"), (OperationKind.simple("activate"), "M01")])
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm.rawValue), world: snapshot
            ) == .wait
        )
    }

    /// Four targets landing active in one round each must bank no credit: the
    /// ferry is the most refusable dispatch and the ladder has to engage on the
    /// very next tick, not four redundant re-sends later.
    @Test("a refused ferry engages the ladder on the next tick")
    func refusedFerryEngagesTheLadderImmediately() {
        let snapshot = armedWorld(
            armedCarried,
            log: armLog(cleanCarriedRounds + [(.setDirective, transportCode)])
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm.rawValue), world: snapshot
            ) == .wait
        )
    }

    /// A Retry keeps the step, re-stamps the clock and writes `.resolved`, so
    /// the loop re-enters holding no record of its own order. Only `arming`
    /// dispatches, so anything but handing back to it re-stalls unchanged.
    @Test("a retried arm stall re-dispatches instead of re-stalling")
    func retriedArmStallReturnsToArming() {
        let snapshot = armedWorld(
            [:],
            log: armLog([(.setDirective, "M01")]) + [
                markerEntry(.stalled, on: MineRun.Step.confirmingArm.rawValue, at: now.addingTimeInterval(-3)),
                markerEntry(.resolved, on: MineRun.Step.confirmingArm.rawValue, at: now.addingTimeInterval(-2)),
            ]
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.arming.rawValue)
        )
    }

    /// An entry that names no order is no evidence of one: the run hands back
    /// to `arming`, which is the only step that can send one (and will write
    /// the typed columns when it does).
    @Test("a dispatch entry naming no order re-dispatches")
    func unnamedDispatchReturnsToArming() {
        let snapshot = armedWorld([:], log: [unnamedDispatch])

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm.rawValue), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.arming.rawValue)
        )
    }

    /// A bot that will not take `service` is its own reason: the fleet reaches
    /// the belt and mines, but nothing repairs it.
    @Test("a service bot past its deadline surfaces as unarmed")
    func unarmedServiceBotSurfaces() {
        let snapshot = armedWorld(
            [
                "M01": (name: "gather_evenly", status: "active", config: [:]),
                "M05": (name: "belt_search", status: "active", config: [:]),
            ],
            log: armLog([(.setDirective, "M01"), (.setDirective, "M05"), (.setDirective, "M08")])
        )
        let directive = mineRunRow(
            step: MineRun.Step.confirmingArm.rawValue,
            stepStartedAt: now.addingTimeInterval(-(MineRun.attachConfirmDeadline + 60))
        )

        #expect(MineRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["M08"], thenStall: .serviceBotNotArmed))
    }

    /// Anything but a bot is a plain rejection — the reason has to name the
    /// device class the operator must look at.
    @Test("a controller past its deadline surfaces as rejected")
    func unarmedControllerSurfaces() {
        let snapshot = armedWorld([:], log: armLog([(.setDirective, "M01")]))
        let directive = mineRunRow(
            step: MineRun.Step.confirmingArm.rawValue,
            stepStartedAt: now.addingTimeInterval(-(MineRun.attachConfirmDeadline + 60))
        )

        #expect(MineRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["M01"], thenStall: .commandRejected))
    }

    // MARK: Returning home

    /// The installed fleet with the carrier standing where `carrierAt` puts it.
    /// `hub` adds what `RelayRun.hubLocation` reads — a print-capable device at a
    /// meshed location the census shows holding stock.
    private func returningWorld(
        carrierAt location: String,
        hub: Bool = true,
        openOperations: [String: GameModels.Operation] = [:],
        dispatchedOperations: [String: GameModels.Operation] = [:],
        carrierUpdatedAt: Date = now
    ) -> WorldSnapshot {
        world(
            devices: beltFleet(adoptedBy: adoptedByController, armed: armedCarried)
                + transportPair(
                    adopted: true,
                    ferry: (collect: targetBelt, deliver: HaulRun.deliveryLocation, status: "active"),
                    at: hub ? hubLocation : HaulRun.deliveryLocation
                )
                + [mineCarrier(location: location, updatedAt: carrierUpdatedAt), beltRelay]
                + (hub ? [printHub, hubRelay] : []),
            openOperations: openOperations,
            dispatchedOperations: dispatchedOperations,
            footprints: hub ? [hubStock] : []
        )
    }

    @Test("an armed fleet on a returning row hands to the return leg")
    func armedFleetReturnsTheCarrier() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.arming.rawValue, returnToOrigin: true),
                world: returningWorld(carrierAt: targetBelt)
            ) == .advanceStep(nextStep: MineRun.Step.returning.rawValue)
        )
    }

    /// The destination is the hub LOCATION, not the belt's system or the row's
    /// origin — the launcher's carrier query demands an exact match.
    @Test("the emptied carrier is flown back to the hub location")
    func returnDispatchesTravelToTheHub() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.returning.rawValue, returnToOrigin: true),
                world: returningWorld(carrierAt: targetBelt)
            ) == .dispatch(
                kind: .travel, deviceCode: carrierCode,
                params: CommandParams(destination: hubLocation),
                nextStep: MineRun.Step.returning.rawValue
            )
        )
    }

    @Test("a carrier standing at the hub finishes the run")
    func carrierHomeFinishes() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.returning.rawValue, returnToOrigin: true),
                world: returningWorld(carrierAt: hubLocation)
            ) == .done
        )
    }

    /// Nowhere to return to is not a fault: the mine is installed either way.
    @Test("no hub leaves the carrier where it stands and finishes")
    func noHubFinishes() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.returning.rawValue, returnToOrigin: true),
                world: returningWorld(carrierAt: targetBelt, hub: false)
            ) == .done
        )
    }

    @Test("a flight already under way is not re-commanded")
    func openTravelHoldsTheReturn() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.returning.rawValue, returnToOrigin: true),
                world: returningWorld(carrierAt: targetBelt, openOperations: openTravel())
            ) == .wait
        )
    }

    /// The outbound leg's watermark, on the way home: a row still lagging the
    /// arrival must not re-command travel at an already-parked carrier.
    @Test("an unresolved arrival watermark defers the return dispatch")
    func returnWaitsOnTheArrivalWatermark() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.returning.rawValue, returnToOrigin: true),
                world: returningWorld(
                    carrierAt: targetBelt, dispatchedOperations: closedTravel(),
                    carrierUpdatedAt: now.addingTimeInterval(-5.139)
                )
            ) == .wait
        )
    }

    /// The flag is the switch: a row without it finishes at the belt, exactly as
    /// every other assertion in this suite expects.
    @Test("a row without returnToOrigin still finishes at the belt")
    func withoutTheFlagTheRunFinishesAtTheBelt() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.arming.rawValue),
                world: returningWorld(carrierAt: targetBelt)
            ) == .done
        )
    }
}

// MARK: - The attach loop through the real engine

/// The attach loop driven end to end through `DirectiveEngineCore` with the
/// real machine. The loop's progress signal is read off the timeline the
/// EXECUTOR writes, so only the real interleaving can prove it.
@Suite("MineRun — the attach loop at the engine", .serialized)
struct MineRunEngineTests {

    private func seed(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Directive.insert { mineRunRow() }.execute(db)
            for row in carriedFleet() + [mineCarrier(), beltRelay] {
                try Device.upsert { row }.execute(db)
            }
        }
    }

    private func step(_ database: any DatabaseWriter) async throws -> String {
        try await database.read { db in
            try Directive.where { $0.id.eq("D1") }.fetchOne(db)?.step
        } ?? ""
    }

    /// Nine rounds of attach and then departure, with each moved row landing a
    /// second BEFORE the step is stamped — what the live affected-device read
    /// produces, and the case a verdict table cannot stage.
    @Test func theAttachLoopReachesTravellingWithoutAFalseStall() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database)
        let ordered = LockIsolated<[String]>([])
        let reads = LockIsolated<[String]>([])
        let reached = LockIsolated("")

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                reads.withValue { $0.append(code) }
                return nil
            }
            $0.commandGovernor.dispatchOwned = { kind, _, params, _ in
                guard kind == .attach, let code = params.devices?.first,
                      let row = carriedFleet().first(where: { $0.deviceCode == code })
                else { return .dispatched(.accepted(operationID: nil)) }
                ordered.withValue { $0.append(code) }
                let aboard = mineRow(
                    code, type: row.deviceType, tags: [MineRecipe.fleetTag.string],
                    location: hubLocation, attachedTo: carrierCode,
                    updatedAt: now.addingTimeInterval(-1)
                )
                try? await database.write { db in try Device.upsert { aboard }.execute(db) }
                return .dispatched(.accepted(operationID: nil))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineRun()], tick: .seconds(5))
            for _ in 0..<24 {
                await core.evaluateOnce(directiveID: "D1")
                let now = try await step(database)
                if now == MineRun.Step.travelling.rawValue {
                    reached.setValue(now)
                    break
                }
            }
        }

        #expect(ordered.value == (1...9).map { "M\(String(format: "%02d", $0))" },
                "every round attaches the NEXT member, so the loop ran nine times")
        #expect(reads.value.isEmpty, "and confirmed each one without buying a device read")
        #expect(reached.value == MineRun.Step.travelling.rawValue)

        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
        )
        #expect(row.status == .running)
        #expect(row.attentionReason == nil)
    }

    private func seedForAdoption(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Directive.insert { mineRunRow(step: MineRun.Step.adopting.rawValue) }.execute(db)
            let rows = beltFleet() + transportPair()
                + [mineCarrier(location: targetBelt), beltRelay]
            for row in rows { try Device.upsert { row }.execute(db) }
        }
    }

    /// Three adoptions and then arming, with each adopted row landing a second
    /// BEFORE the step is stamped — what the live affected-device read produces.
    @Test func theAdoptLoopReachesArmingWithoutAFalseStall() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedForAdoption(database)
        let ordered = LockIsolated<[[String]]>([])
        let reads = LockIsolated<[String]>([])
        let reached = LockIsolated("")

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                reads.withValue { $0.append(code) }
                return nil
            }
            $0.commandGovernor.dispatchOwned = { kind, controller, params, _ in
                guard kind == .adopt, let devices = params.devices else {
                    return .dispatched(.accepted(operationID: nil))
                }
                ordered.withValue { $0.append(devices) }
                let existing = beltFleet() + transportPair()
                try? await database.write { db in
                    for code in devices {
                        guard let row = existing.first(where: { $0.deviceCode == code }) else { continue }
                        let adopted = mineRow(
                            code, type: row.deviceType, tags: [MineRecipe.fleetTag.string],
                            location: row.location, controlledBy: controller,
                            updatedAt: now.addingTimeInterval(-1)
                        )
                        try Device.upsert { adopted }.execute(db)
                    }
                }
                return .dispatched(.accepted(operationID: nil))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineRun()], tick: .seconds(5))
            for _ in 0..<12 {
                await core.evaluateOnce(directiveID: "D1")
                let now = try await step(database)
                if now == MineRun.Step.arming.rawValue {
                    reached.setValue(now)
                    break
                }
            }
        }

        #expect(ordered.value == [["M02", "M03", "M04"], ["M06", "M07"], [freighterCode]])
        #expect(reads.value.isEmpty, "and confirmed each one without buying a device read")
        #expect(reached.value == MineRun.Step.arming.rawValue)

        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
        )
        #expect(row.status == .running)
        #expect(row.attentionReason == nil)
    }

    private static let armedRows = beltFleet(adoptedBy: adoptedByController)
        + transportPair(adopted: true)

    private func seedForArming(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Directive.insert { mineRunRow(step: MineRun.Step.arming.rawValue) }.execute(db)
            let rows = Self.armedRows + [mineCarrier(location: targetBelt), beltRelay]
            for row in rows { try Device.upsert { row }.execute(db) }
        }
    }

    /// Five targets armed through the real executor, the mining controller
    /// taking its directive PAUSED so the activate split runs — the one shape
    /// that proves the confirm reads the verb the executor actually logged.
    @Test func theArmLoopReachesDoneThroughTheActivateSplit() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedForArming(database)
        let ordered = LockIsolated<[String]>([])
        let reads = LockIsolated<[String]>([])
        let armed = LockIsolated<[String: InForce]>([:])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.deviceRefresher.refresh = { code, _ in
                reads.withValue { $0.append(code) }
                return nil
            }
            $0.commandGovernor.dispatchOwned = { kind, code, params, _ in
                ordered.withValue { $0.append("\(kind.rawValue) \(code)") }
                armed.withValue {
                    if let directive = params.directive {
                        $0[code] = (
                            name: directive, status: code == "M01" ? "paused" : "active",
                            config: params.configuration ?? [:]
                        )
                    } else if let held = $0[code] {
                        $0[code] = (name: held.name, status: "active", config: held.config)
                    }
                }
                guard let base = Self.armedRows.first(where: { $0.deviceCode == code })
                else { return .dispatched(.accepted(operationID: nil)) }
                let row = mineRow(
                    code, type: base.deviceType, tags: [MineRecipe.fleetTag.string],
                    location: base.location, controlledBy: base.controllerDeviceCode,
                    directive: armed.value[code], updatedAt: now.addingTimeInterval(-1)
                )
                try? await database.write { db in try Device.upsert { row }.execute(db) }
                return .dispatched(.accepted(operationID: nil))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineRun()], tick: .seconds(5))
            for _ in 0..<20 {
                await core.evaluateOnce(directiveID: "D1")
                let row = try await database.read { db in
                    try Directive.where { $0.id.eq("D1") }.fetchOne(db)
                }
                if row?.status == .completed { break }
            }
        }

        #expect(ordered.value == [
            "set_directive M01", "activate M01", "set_directive M05",
            "set_directive M08", "set_directive M09", "set_directive \(transportCode)",
        ])
        #expect(reads.value.isEmpty, "and confirmed each one without buying a device read")
        #expect(
            armed.value[transportCode]?.config["collect"] == .string(targetBelt),
            "the ferry names this run's belt"
        )

        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
        )
        #expect(row.status == .completed)
        #expect(row.attentionReason == nil)
    }
}
