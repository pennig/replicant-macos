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
                "M\(String(format: "%02d", n))", type: type, tags: [MineRecipe.fleetTag],
                location: location, attachedTo: n <= attached ? carrierCode : nil,
                updatedAt: updatedAt
            ))
        }
    }
    return out
}

private func mineCarrier(location: String? = hubLocation, updatedAt: Date = now) -> Device {
    mineRow(
        carrierCode, type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag],
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
    "X01", type: "ami_mining_controller", tags: [MineRecipe.fleetTag], location: targetBelt
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
                code, type: type, tags: [MineRecipe.fleetTag], location: targetBelt,
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
    ferry: (collect: String, deliver: String, status: String)? = nil,
    at location: String = HaulRun.deliveryLocation,
    updatedAt: Date = now
) -> [Device] {
    [
        mineRow(
            transportCode, type: "ami_transport_controller", tags: [MineRecipe.fleetTag],
            location: location,
            directive: ferry.map {
                (
                    name: HaulTargetPlanner.ferry, status: $0.status,
                    config: ["collect": .string($0.collect), "deliver": .string($0.deliver)]
                )
            },
            updatedAt: updatedAt
        ),
        mineRow(
            freighterCode, type: "cargo_freighter", tags: [MineRecipe.fleetTag],
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

/// A print-capable device at a meshed location the census shows holding stock —
/// what makes `HaulRun.deliverySink` resolve to something other than its fallback.
private let printHub = mineRow(
    "HUB1", type: "autofactory", location: hubLocation, commands: ["enqueue_print"]
)

private let hubRelay = mineRow(
    "RLY2", type: "ftl_relay", location: hubLocation, status: "relaying", features: ["relay"]
)

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    log: [DirectiveLogEntry] = [],
    dispatchedOperations: [String: GameModels.Operation] = [:],
    footprints: [LocationFootprint] = []
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: log, dispatchedOperations: dispatchedOperations,
        footprints: Dictionary(footprints.map { ($0.location, $0) }, uniquingKeysWith: { _, last in last }),
        now: now
    )
}

private func mineRunRow(
    step: String = MineRun.Step.preflight,
    targets: [String] = [targetBelt],
    stepStartedAt: Date = now.addingTimeInterval(-60),
    deviceCode: String = carrierCode
) -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: deviceCode,
        controllerCode: nil, roamCentre: nil, fleetTag: MineRecipe.fleetTag, sourceRelayCode: nil,
        targets: targets, targetIndex: 0, step: step, stepStartedAt: stepStartedAt,
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: now.addingTimeInterval(-600), updatedAt: now
    )
}

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
        out.append(logEntry(MineRun.Step.attaching, at: base))
        out.append(logEntry(MineRun.Step.confirmingAttach, at: base.addingTimeInterval(1)))
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
        #expect(MissionRegistry.firstStep(for: .mineRun) == MineRun.Step.preflight)
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

    @Test("a staged fleet at a meshed belt starts attaching")
    func stagedFleetAdvances() {
        let snapshot = world(devices: carriedFleet() + [mineCarrier(), beltRelay])

        #expect(MineRun().nextAction(directive: mineRunRow(), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.attaching))
    }

    // MARK: Attaching

    /// One at a time, lowest-coded first, and never naming its own step:
    /// `attach` is immediate, so no operation row could gate a re-dispatch.
    @Test("the first attach names the lowest-coded member")
    func attachDispatchesTheLowestCodedMember() {
        let snapshot = world(devices: carriedFleet() + [mineCarrier(), beltRelay])

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.attaching), world: snapshot)
                == .dispatch(
                    kind: .attach, deviceCode: carrierCode,
                    params: CommandParams(devices: ["M01"]),
                    nextStep: MineRun.Step.confirmingAttach
                )
        )
    }

    /// The pick is stable: four rows in, the run reaches for the fifth and
    /// keeps reaching for it until it lands.
    @Test("a part-attached fleet dispatches the next member, twice over")
    func attachChoiceIsStable() {
        let snapshot = world(devices: carriedFleet(attached: 4) + [mineCarrier(), beltRelay])
        let directive = mineRunRow(step: MineRun.Step.attaching)

        let first = MineRun().nextAction(directive: directive, world: snapshot)
        let second = MineRun().nextAction(directive: directive, world: snapshot)

        #expect(first == .dispatch(
            kind: .attach, deviceCode: carrierCode, params: CommandParams(devices: ["M05"]),
            nextStep: MineRun.Step.confirmingAttach
        ))
        #expect(first == second)
    }

    @Test("a fully attached fleet travels")
    func fullyAttachedFleetTravels() {
        let snapshot = world(devices: carriedFleet(attached: 9) + [mineCarrier(), beltRelay])

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.attaching), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.travelling))
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
                directive: mineRunRow(step: MineRun.Step.confirmingAttach), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.attaching)
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
                directive: mineRunRow(step: MineRun.Step.confirmingAttach), world: snapshot
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
            step: MineRun.Step.confirmingAttach,
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
                directive: mineRunRow(step: MineRun.Step.confirmingAttach), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.attaching)
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
        let directive = mineRunRow(step: MineRun.Step.confirmingAttach)

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
                directive: mineRunRow(step: MineRun.Step.confirmingAttach), world: snapshot
            ) == .wait
        )
    }

    // MARK: Travelling

    @Test("the loaded carrier is flown to the belt")
    func travelDispatches() {
        let snapshot = world(devices: carriedFleet(attached: 9) + [mineCarrier(), beltRelay])

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.travelling), world: snapshot)
                == .dispatch(
                    kind: .travel, deviceCode: carrierCode,
                    params: CommandParams(destination: targetBelt),
                    nextStep: MineRun.Step.confirmingArrival
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

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.travelling), world: snapshot)
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

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.travelling), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.detaching))
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
                directive: mineRunRow(step: MineRun.Step.confirmingArrival), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.detaching)
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
                directive: mineRunRow(step: MineRun.Step.confirmingArrival), world: snapshot
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
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.detaching), world: snapshot)
                == .dispatch(
                    kind: .detach, deviceCode: carrierCode,
                    params: CommandParams(devices: (1...9).map { "M\(String(format: "%02d", $0))" }),
                    nextStep: MineRun.Step.confirmingDetach
                )
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
                directive: mineRunRow(step: MineRun.Step.confirmingDetach), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.adopting)
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
            directive: mineRunRow(step: MineRun.Step.confirmingDetach), world: snapshot
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
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting), world: snapshot)
                == .dispatch(
                    kind: .adopt, deviceCode: "M01",
                    params: CommandParams(devices: ["M02", "M03", "M04"]),
                    nextStep: MineRun.Step.confirmingAdopt
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
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting), world: snapshot)
                == .dispatch(
                    kind: .adopt, deviceCode: "M05",
                    params: CommandParams(devices: ["M06", "M07"]),
                    nextStep: MineRun.Step.confirmingAdopt
                )
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
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting), world: snapshot)
                == .dispatch(
                    kind: .adopt, deviceCode: transportCode,
                    params: CommandParams(devices: [freighterCode]),
                    nextStep: MineRun.Step.confirmingAdopt
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
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting), world: snapshot)
                == .advanceStep(nextStep: MineRun.Step.arming)
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
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.adopting), world: snapshot)
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
            log: loopLog(MineRun.Step.adopting, MineRun.Step.confirmingAdopt, rounds: 1)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAdopt), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.adopting)
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
            log: loopLog(MineRun.Step.adopting, MineRun.Step.confirmingAdopt, rounds: 2)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingAdopt), world: snapshot
            ) == .refreshDevices(deviceCodes: ["M06", "M07"], thenStall: nil)
        )
    }

    @Test("an adoption past its deadline spends one last read and surfaces")
    func adoptionDeadlineSurfaces() {
        let snapshot = world(
            devices: beltFleet(updatedAt: now.addingTimeInterval(-900)) + transportPair()
                + [mineCarrier(location: targetBelt), beltRelay],
            log: loopLog(MineRun.Step.adopting, MineRun.Step.confirmingAdopt, rounds: 1)
        )
        let directive = mineRunRow(
            step: MineRun.Step.confirmingAdopt,
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
                directive: mineRunRow(step: MineRun.Step.arming), world: armedWorld([:])
            ) == .dispatch(
                kind: .setDirective, deviceCode: "M01",
                params: CommandParams(directive: "gather_evenly", configuration: nil),
                nextStep: MineRun.Step.confirmingArm
            )
        )
    }

    /// Right directive, not running: `activate` is what starts it. Re-sending
    /// the name would never touch the status.
    @Test("a paused directive is activated, not re-sent")
    func armActivatesAPausedDirective() {
        let snapshot = armedWorld(["M01": (name: "gather_evenly", status: "paused", config: [:])])

        #expect(
            MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming), world: snapshot)
                == .dispatch(
                    kind: OperationKind.simple("activate"), deviceCode: "M01",
                    params: CommandParams(), nextStep: MineRun.Step.confirmingArm
                )
        )
    }

    @Test("four armed leaves the ferry, configured for this belt")
    func armDispatchesTheFerryLast() {
        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.arming), world: armedWorld(armedCarried)
            ) == .dispatch(
                kind: .setDirective, deviceCode: transportCode,
                params: CommandParams(
                    directive: HaulTargetPlanner.ferry,
                    configuration: [
                        "collect": .string(targetBelt),
                        "deliver": .string(HaulRun.deliveryLocation),
                    ]
                ),
                nextStep: MineRun.Step.confirmingArm
            )
        )
    }

    @Test("all five in force and running finishes the run")
    func allFiveArmedIsDone() {
        let snapshot = armedWorld(
            armedCarried,
            ferry: (collect: targetBelt, deliver: HaulRun.deliveryLocation, status: "active")
        )

        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming), world: snapshot)
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

        #expect(HaulRun.deliverySink(in: snapshot) == hubLocation)
        #expect(MineRun().nextAction(directive: mineRunRow(step: MineRun.Step.arming), world: snapshot)
                == .done)
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

    // MARK: Confirming an arming

    @Test("every target in force and running goes back to arming")
    func confirmArmLoopsWhenAllFiveLanded() {
        let snapshot = armedWorld(
            armedCarried,
            ferry: (collect: targetBelt, deliver: HaulRun.deliveryLocation, status: "active"),
            log: loopLog(MineRun.Step.arming, MineRun.Step.confirmingArm, rounds: 5)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.arming)
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
            log: loopLog(MineRun.Step.arming, MineRun.Step.confirmingArm, rounds: 1)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm), world: snapshot
            ) == .advanceStep(nextStep: MineRun.Step.arming)
        )
    }

    /// The activate has not landed: the directive is in force but still paused
    /// after two rounds, so the ladder holds rather than ordering a third.
    @Test("an activate still outstanding engages the ladder")
    func outstandingActivateEngagesTheLadder() {
        let snapshot = armedWorld(
            ["M01": (name: "gather_evenly", status: "paused", config: [:])],
            log: loopLog(MineRun.Step.arming, MineRun.Step.confirmingArm, rounds: 2)
        )

        #expect(
            MineRun().nextAction(
                directive: mineRunRow(step: MineRun.Step.confirmingArm), world: snapshot
            ) == .wait
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
            log: loopLog(MineRun.Step.arming, MineRun.Step.confirmingArm, rounds: 5)
        )
        let directive = mineRunRow(
            step: MineRun.Step.confirmingArm,
            stepStartedAt: now.addingTimeInterval(-(MineRun.attachConfirmDeadline + 60))
        )

        #expect(MineRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["M08"], thenStall: .serviceBotNotArmed))
    }

    /// Anything but a bot is a plain rejection — the reason has to name the
    /// device class the operator must look at.
    @Test("a controller past its deadline surfaces as rejected")
    func unarmedControllerSurfaces() {
        let snapshot = armedWorld(
            [:], log: loopLog(MineRun.Step.arming, MineRun.Step.confirmingArm, rounds: 5)
        )
        let directive = mineRunRow(
            step: MineRun.Step.confirmingArm,
            stepStartedAt: now.addingTimeInterval(-(MineRun.attachConfirmDeadline + 60))
        )

        #expect(MineRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["M01"], thenStall: .commandRejected))
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
            $0.commandGovernor.dispatch = { kind, _, params in
                guard kind == .attach, let code = params.devices?.first,
                      let row = carriedFleet().first(where: { $0.deviceCode == code })
                else { return .dispatched(.accepted(operationID: nil)) }
                ordered.withValue { $0.append(code) }
                let aboard = mineRow(
                    code, type: row.deviceType, tags: [MineRecipe.fleetTag],
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
                if now == MineRun.Step.travelling {
                    reached.setValue(now)
                    break
                }
            }
        }

        #expect(ordered.value == (1...9).map { "M\(String(format: "%02d", $0))" },
                "every round attaches the NEXT member, so the loop ran nine times")
        #expect(reads.value.isEmpty, "and confirmed each one without buying a device read")
        #expect(reached.value == MineRun.Step.travelling)

        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
        )
        #expect(row.status == .running)
        #expect(row.attentionReason == nil)
    }

    private func seedForAdoption(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Directive.insert { mineRunRow(step: MineRun.Step.adopting) }.execute(db)
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
            $0.commandGovernor.dispatch = { kind, controller, params in
                guard kind == .adopt, let devices = params.devices else {
                    return .dispatched(.accepted(operationID: nil))
                }
                ordered.withValue { $0.append(devices) }
                let existing = beltFleet() + transportPair()
                try? await database.write { db in
                    for code in devices {
                        guard let row = existing.first(where: { $0.deviceCode == code }) else { continue }
                        let adopted = mineRow(
                            code, type: row.deviceType, tags: [MineRecipe.fleetTag],
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
                if now == MineRun.Step.arming {
                    reached.setValue(now)
                    break
                }
            }
        }

        #expect(ordered.value == [["M02", "M03", "M04"], ["M06", "M07"], [freighterCode]])
        #expect(reads.value.isEmpty, "and confirmed each one without buying a device read")
        #expect(reached.value == MineRun.Step.arming)

        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
        )
        #expect(row.status == .running)
        #expect(row.attentionReason == nil)
    }
}
