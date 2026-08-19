//
//  EventRunPrintTests.swift
//  Replicould — DirectiveEngine
//
//  C3 and C4: `EventRun.printing`'s bench capability and busy guard, once it
//  adopts `PrintScheduler` instead of its own hand-rolled printer filter.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)
private let depot = "HUB-1"
private let elsewhere = "SAGARMADHA"

/// A print-capable device standing at `depot`, ready for the printing step.
/// `printing` seeds a `printing` block on its own snapshot, as a bench mid-job
/// reports one.
private func bench(
    _ code: String, type: String = "autofactory", at location: String = depot,
    commands: [String] = ["enqueue_print"], printing: String? = nil
) -> Device {
    var device = EventRunFixtures.device(
        code, type: type, location: location, updatedAt: now, commands: commands
    )
    if let printing {
        device.detail = .object(["printing": .object(["device_type": .string(printing)])])
    }
    return device
}

/// An open op on `entity`, owned by `owner` — nil reads as no owner at all.
private func op(
    on entity: String, owner: String?, deviceType: String? = nil, quantity: Int? = nil
) -> GameModels.Operation {
    var params: [String: JSONValue] = [:]
    if let deviceType { params["device_type"] = .string(deviceType) }
    if let quantity { params["quantity"] = .number(Double(quantity)) }
    return GameModels.Operation(
        id: "OP-\(entity)", entityCode: entity, kind: OperationKind.print.rawValue,
        status: .active, source: .poll, startedAt: now, completesAt: nil,
        lastConfirmedAt: now, detail: .object(["params": .object(params)]), directiveID: owner
    )
}

/// A world at the printing step: the run's carrier, the given benches, and one
/// top-level device requirement per `wanting`, unmet by anything standing.
private func worldPrinting(
    depot: String, devices: [Device], open: [String: GameModels.Operation] = [:],
    wanting: [String: Int]
) -> WorldSnapshot {
    let carrier = EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1")
    let event = EventRunFixtures.event(
        devices: wanting.sorted { $0.key < $1.key }.map { ($0.value, $0.key) }
    )
    return EventRunFixtures.world(
        devices: [carrier] + devices, event: event, now: now, openOperations: open
    )
}

private func printingRow() -> Directive {
    EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now)
}

@Suite("EventRun — printing adopts the scheduler")
struct EventRunPrintSchedulerTests {

    /// A depot's bench capability is `acceptsPrintJobs && !isCarrierHull`, so
    /// any print-capable vessel qualifies — not only a device typed
    /// `autofactory`.
    @Test("a print vessel that is not an autofactory is a bench")
    func printVesselIsABench() {
        let vessel = bench("B1", type: "fabricator_barge", commands: ["enqueue_print"])
        let world = worldPrinting(depot: depot, devices: [vessel], wanting: ["ftl_beacon": 1])

        guard case let .dispatch(_, deviceCode, _, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B1")
    }

    /// A bench carrying someone else's print is busy only for itself — a free
    /// sibling at the same depot still takes this run's dispatch.
    @Test("a co-tenant's print occupies only its own bench")
    func coTenantOccupiesOnlyItsOwnBench() {
        let world = worldPrinting(
            depot: depot, devices: [bench("B1", printing: "mining_drone"), bench("B2")],
            open: ["B1": op(on: "B1", owner: "OTHER")], wanting: ["ftl_beacon": 1]
        )

        guard case let .dispatch(_, deviceCode, _, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B2")
    }

    /// The real owner+depot leak was `printsInFlight`'s netting: no depot
    /// filter at all. Pinned here against its replacement,
    /// `PrintScheduler.onOrder`.
    @Test("this directive's own open print at another depot does not net here")
    func anotherDepotsPrintDoesNotNetHere() {
        let far = bench("FAR", at: elsewhere)
        let world = worldPrinting(
            depot: depot, devices: [bench("B1"), far],
            open: ["FAR": op(on: "FAR", owner: "d1", deviceType: "ftl_beacon", quantity: 1)],
            wanting: ["ftl_beacon": 1]
        )

        guard case let .dispatch(_, deviceCode, params, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B1")
        #expect(params.quantity == 1)
    }

    /// A depot standing zero print-capable devices stalls outright — a
    /// permanent condition, never `noProgress`'s wait-or-deadline path.
    @Test("a depot with no benches at all stalls rather than waiting")
    func noBenchesAtAllStalls() {
        let mesh = EventRunFixtures.device("MESH", type: "ftl_relay", location: depot, updatedAt: now)
        let world = worldPrinting(depot: depot, devices: [mesh], wanting: ["ftl_beacon": 1])

        let action = EventRun().nextAction(directive: printingRow(), world: world)
        #expect(action == .stall(.unreachableDevice))
    }
}
