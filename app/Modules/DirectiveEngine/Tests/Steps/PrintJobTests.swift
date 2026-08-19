//
//  PrintJobTests.swift
//  Replicould — DirectiveEngine
//
//  The print frame: which bench takes the job, which depot anchors it, whether
//  the fleet evidence is good enough, and whether our own print is still open.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let depot = "AINALRAM-BELT-1"
private let elsewhere = "SAGARMADHA"

private func bench(
    _ code: String, status: String = "idle", location: String? = depot,
    features: [String] = [], commands: [String] = ["enqueue_print"],
    updatedAt: Date = now
) -> Device {
    Device(
        deviceCode: code, deviceType: "autofactory", replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: commands,
        features: features, tags: [], detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func op(
    on entity: String, owner: String?, status: OperationStatus = .active,
    kind: String = OperationKind.print.rawValue
) -> GameModels.Operation {
    GameModels.Operation(
        id: "OP-\(entity)", entityCode: entity, kind: kind,
        status: status, source: .poll, startedAt: now, completesAt: nil,
        lastConfirmedAt: now, detail: .object([:]), directiveID: owner
    )
}

private func row(pin: String, stamped: String? = depot, startedAgo: TimeInterval = 60) -> Directive {
    Directive(
        id: "P1", kind: .mineFleetPrint, status: .running, deviceCode: pin,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: [], targetIndex: 0, step: MineFleetPrint.Step.stocking.rawValue,
        stepStartedAt: now.addingTimeInterval(-startedAgo),
        returnToOrigin: false, originDesignation: "AINALRAM", attentionReason: nil,
        createdAt: now.addingTimeInterval(-600), updatedAt: now, theatreDepot: stamped
    )
}

private func snapshot(
    _ devices: [Device], open: [String: GameModels.Operation] = [:],
    dispatched: [String: GameModels.Operation] = [:]
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: open, dispatchedOperations: dispatched, now: now
    )
}

private func ctx(
    _ devices: [Device], pin: String = "B1", stamped: String? = depot,
    open: [String: GameModels.Operation] = [:],
    dispatched: [String: GameModels.Operation] = [:],
    startedAgo: TimeInterval = 60
) -> StepContext {
    let directive = row(pin: pin, stamped: stamped, startedAgo: startedAgo)
    return StepContext(
        directive: directive, world: snapshot(devices, open: open, dispatched: dispatched),
        step: directive.step
    )
}

@Suite("Print job")
struct PrintJobTests {
    private let job = PrintJob(depot: depot)

    // MARK: - The poll

    /// The chooser skips a bench with an open op, so at poll time it names a
    /// bench our job is NOT on. Only the ops table can answer "is mine open?".
    @Test("our own print on a substituted bench still reads as printing")
    func ownPrintOnASubstituteIsStillPrinting() {
        let pin = bench("B1", status: "compacted")
        let holding = bench("B2")
        let free = bench("B3")
        let mine = op(on: "B2", owner: "P1")
        let frame = ctx(
            [pin, holding, free], open: ["B2": mine], dispatched: ["OP-B2": mine]
        )

        #expect(job.stillPrinting(frame))
        // The whole point: the chooser has already moved on to the free bench.
        #expect(job.bench(frame)?.deviceCode == "B3")
    }

    @Test("no operations anywhere is not printing")
    func noOperationsIsNotPrinting() {
        #expect(!job.stillPrinting(ctx([bench("B1")])))
    }

    /// `openOperation(for:owner:)` never filters out an op with no owner, and
    /// the poll it replaced inherited that. It has to keep inheriting it.
    @Test("an unowned op on the pinned bench still reads as printing")
    func anUnownedOpOnThePinIsStillPrinting() {
        let frame = ctx([bench("B1")], open: ["B1": op(on: "B1", owner: nil)])

        #expect(job.stillPrinting(frame))
    }

    /// `dispatchedOperations` is directive-scoped by construction, and the
    /// legacy half of it carries no owner column at all — those rows are ours.
    @Test("a legacy print with no owner on a substituted bench is still ours")
    func aLegacyUnownedPrintOnASubstituteIsOurs() {
        let legacy = op(on: "B2", owner: nil)
        let frame = ctx(
            [bench("B1", status: "compacted"), bench("B2"), bench("B3")],
            open: ["B2": legacy], dispatched: ["OP-B2": legacy]
        )

        #expect(job.stillPrinting(frame))
    }

    /// `dispatchedOperations` retains closed ops on purpose, so without the
    /// liveness filter the poll would hold the step for a whole deadline.
    @Test("our own print that has completed is no longer printing")
    func aCompletedPrintIsNotStillPrinting() {
        let done = op(on: "B2", owner: "P1", status: .completed)
        let frame = ctx([bench("B1", status: "compacted"), bench("B2")], dispatched: ["OP-B2": done])

        #expect(!job.stillPrinting(frame))
    }

    @Test("our own travel op is not a print")
    func aTravelOpIsNotAPrint() {
        let trip = op(on: "B2", owner: "P1", kind: OperationKind.travel.rawValue)
        let frame = ctx([bench("B1", status: "compacted"), bench("B2")], dispatched: ["OP-B2": trip])

        #expect(!job.stillPrinting(frame))
    }

    // MARK: - The deadline

    /// The engine's one 1800. Every reader aliases onto it, so a wrong value
    /// here would move every print deadline together and unseen.
    @Test("the print deadline is the single root its aliases point at")
    func theDeadlineIsTheOneRoot() {
        #expect(PrintJob.deadline == 30 * 60)
        #expect(RelayRun.printDeadline == PrintJob.deadline)
        #expect(RestockRun.printDeadline == PrintJob.deadline)
    }

    // MARK: - The bench

    @Test("a pinned bench that accepts jobs at the depot keeps them")
    func pinnedBenchKeepsTheJob() {
        #expect(job.bench(ctx([bench("B9"), bench("B0")], pin: "B9"))?.deviceCode == "B9")
    }

    @Test("a pin that cannot take the job hands it to the lowest-coded free bench")
    func substituteIsTheLowestCodedFreeBench() {
        let queued = op(on: "B2", owner: "OTHER")
        let frame = ctx(
            [bench("B1", status: "compacted"), bench("B2"), bench("B7")],
            open: ["B2": queued]
        )

        #expect(job.bench(frame)?.deviceCode == "B7")
    }

    @Test("with every bench queued the lowest code is still chosen")
    func allBusyFallsBackToTheLowestCode() {
        let frame = ctx(
            [bench("B1", status: "compacted"), bench("B2"), bench("B7")],
            open: ["B2": op(on: "B2", owner: "OTHER"), "B7": op(on: "B7", owner: "OTHER")]
        )

        #expect(job.bench(frame)?.deviceCode == "B2")
    }

    /// A carrier hull advertises `enqueue_print`; printing the fleet into the
    /// vehicle meant to carry it is not a substitution this rule may make.
    @Test("a carrier hull is never a substitute bench")
    func carrierHullIsNeverASubstitute() {
        let hull = bench("B2", features: ["cradle", "surge"])
        let frame = ctx([bench("B1", status: "compacted"), hull])

        #expect(job.bench(frame) == nil)
    }

    @Test("a bench standing away from the depot is not a substitute")
    func aBenchAwayFromTheDepotIsNotASubstitute() {
        let frame = ctx([bench("B1", status: "compacted"), bench("B2", location: elsewhere)])

        #expect(job.bench(frame) == nil)
    }

    // MARK: - The depot

    @Test("the stamped theatre outranks where the pin is standing")
    func stampedTheatreWinsOverThePin() {
        let world = snapshot([bench("B1", location: elsewhere)])

        #expect(PrintJob.depot(for: row(pin: "B1"), in: world) == depot)
    }

    @Test("an unstamped row resolves through its own pin")
    func anUnstampedRowResolvesThroughItsPin() {
        let world = snapshot([bench("B1", location: elsewhere)])

        #expect(PrintJob.depot(for: row(pin: "B1", stamped: nil), in: world) == elsewhere)
    }

    @Test("neither a stamp nor a placed pin resolves to nothing")
    func neitherStampNorPinIsNil() {
        #expect(PrintJob.depot(for: row(pin: "B1", stamped: nil), in: snapshot([])) == nil)
        #expect(
            PrintJob.depot(for: row(pin: "B1", stamped: nil), in: snapshot([bench("B1", location: nil)]))
                == nil
        )
    }

    // MARK: - The evidence

    @Test("no rows at the location is stale evidence")
    func noRowsAtTheLocationIsStale() {
        let world = snapshot([bench("B1", location: elsewhere)])

        #expect(PrintJob.fleetEvidenceIsStale(row(pin: "B1"), at: depot, in: world))
    }

    @Test("every row predating the step is stale evidence")
    func everyRowPredatingTheStepIsStale() {
        let world = snapshot([
            bench("B1", updatedAt: now.addingTimeInterval(-600)),
            bench("B2", updatedAt: now.addingTimeInterval(-120)),
        ])

        #expect(PrintJob.fleetEvidenceIsStale(row(pin: "B1"), at: depot, in: world))
    }

    @Test("one row newer than the step start is evidence enough")
    func oneFreshRowIsEnough() {
        let world = snapshot([
            bench("B1", updatedAt: now.addingTimeInterval(-600)),
            bench("B2", updatedAt: now.addingTimeInterval(-30)),
        ])

        #expect(!PrintJob.fleetEvidenceIsStale(row(pin: "B1"), at: depot, in: world))
    }
}
