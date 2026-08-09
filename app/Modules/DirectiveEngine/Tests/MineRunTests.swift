//
//  MineRunTests.swift
//  Replicould — DirectiveEngine
//
//  `MineRun` as a verdict table: preflight, the attach loop, the ferry, and
//  the detach at the belt.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let hubLocation = "AINALRAM-3"
private let targetBelt = "TOSLIT-4-BELT-1"
private let carrierCode = "SC1"

private func mineRow(
    _ code: String, type: String, tags: [String] = [], location: String? = nil,
    status: String = "idle", attachedTo: String? = nil, features: [String] = [],
    updatedAt: Date = now
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: attachedTo, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: features, tags: tags, detail: .object([:]),
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

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    log: [DirectiveLogEntry] = [],
    dispatchedOperations: [String: GameModels.Operation] = [:]
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: log, dispatchedOperations: dispatchedOperations,
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
}
