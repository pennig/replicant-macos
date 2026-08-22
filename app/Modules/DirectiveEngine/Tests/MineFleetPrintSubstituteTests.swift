//
//  MineFleetPrintSubstituteTests.swift
//  Replicould — DirectiveEngine
//
//  Which hub a print run uses when the one it was launched with cannot take a job.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
@testable import DirectiveEngine

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let depot = "AINALRAM-BELT-1"
private let awayLocation = "SAGARMADHA"

private func device(
    _ code: String, type: String, status: String = "idle", location: String? = depot,
    tags: [String] = [], features: [String] = [], commands: [String] = [], queueSize: Int = 0
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: queueSize,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: commands,
        features: features, tags: tags, detail: .object([:]),
        updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A print hub in a named status — the one axis every test here turns.
private func bench(_ code: String, status: String, location: String? = depot, queueSize: Int = 0) -> Device {
    device(
        code, type: "autofactory", status: status, location: location,
        commands: ["enqueue_print"], queueSize: queueSize
    )
}

/// A mine fleet one mining drone short, so `stocking` always has work to dispatch.
private func shortFleet() -> [Device] {
    var out: [Device] = []
    var n = 0
    for (type, quantity) in MineRecipe.all {
        let wanted = type == "mining_drone" ? quantity - 1 : quantity
        for _ in 0..<wanted {
            n += 1
            out.append(device(
                "M\(String(format: "%02d", n))", type: type, tags: [MineRecipe.fleetTag.string]
            ))
        }
    }
    out.append(device("SC1", type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag.string]))
    return out
}

/// An open print op on `entity`, so a test can stand a bench in a queue.
private func openPrint(on entity: String) -> [String: GameModels.Operation] {
    [entity: GameModels.Operation(
        id: "OP-\(entity)", entityCode: entity, kind: OperationKind.print.rawValue, status: .active,
        source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now, detail: .object([:])
    )]
}

private func world(
    _ devices: [Device], busy: [String: GameModels.Operation] = [:]
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: busy, log: [], dispatchedOperations: [:], systems: [:], siteAssays: [:],
        footprints: [depot: LocationFootprint(
            location: depot, devices: 1, resources: 1_000_000,
            resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
        )],
        inventories: railClearingInventory(at: depot, fetchedAt: now),
        peers: [], now: now
    )
}

private func run(hub code: String, depot stamped: String? = depot) -> Directive {
    Directive(
        id: "P1", kind: .mineFleetPrint, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: MineRecipe.fleetTag.string,
        sourceRelayCode: nil, targets: [], targetIndex: 0,
        step: MineFleetPrint.Step.stocking.rawValue, stepStartedAt: now.addingTimeInterval(-60),
        returnToOrigin: false, originDesignation: "AINALRAM", attentionReason: nil,
        createdAt: now.addingTimeInterval(-600), updatedAt: now, theatreDepot: stamped
    )
}

/// The device a `.dispatch` was aimed at, so a test can name the hub chosen.
private func target(of action: MissionAction) -> String? {
    guard case let .dispatch(_, deviceCode, _, _) = action else { return nil }
    return deviceCode
}

// MARK: - Tests

@Suite("MineFleetPrint — a hub that cannot take the job")
struct MineFleetPrintSubstituteTests {

    /// The live incident: the hub was compacted for carriage and the server
    /// refused the enqueue, while three able hubs stood at the same bench.
    @Test("a compacted hub hands the job to an able one at the depot")
    func compactedHubIsReplaced() {
        let snapshot = world(shortFleet() + [bench("AF1", status: "compacted"), bench("AF2", status: "idle")])

        #expect(target(of: MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot)) == "AF2")
    }

    /// The second rejection that incident produced, once the hub was under way.
    @Test("a travelling hub hands the job over too")
    func travellingHubIsReplaced() {
        let snapshot = world(shortFleet() + [
            bench("AF1", status: "travelling", location: nil), bench("AF2", status: "idle"),
        ])

        #expect(target(of: MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot)) == "AF2")
    }

    /// A hub that flew off and settled elsewhere must not drag the run with it:
    /// the depot names the bench, not whatever the pinned row now reports.
    @Test("a hub that arrived elsewhere still prints at the depot")
    func arrivedElsewhereStillPrintsAtTheDepot() {
        let snapshot = world(shortFleet() + [
            bench("AF1", status: "idle", location: awayLocation), bench("AF2", status: "idle"),
        ])

        #expect(target(of: MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot)) == "AF2")
    }

    /// The pin carries no stickiness: with two free benches, the lowest code
    /// wins, whichever one launched the row.
    @Test("a lower-coded free sibling wins over the pin")
    func lowerCodedSiblingWinsOverThePin() {
        let snapshot = world(shortFleet() + [bench("AF0", status: "idle"), bench("AF9", status: "idle")])

        #expect(target(of: MineFleetPrint().nextAction(directive: run(hub: "AF9"), world: snapshot)) == "AF0")
    }

    /// Jobs queue, so a hub mid-print is still the right hub — `isBusy` would have
    /// skipped it and started a needless second queue beside it.
    @Test("a hub already printing keeps the job")
    func printingHubKeepsTheJob() {
        let snapshot = world(shortFleet() + [
            bench("AF1", status: "printing (ftl_relay)"), bench("AF2", status: "idle"),
        ])

        #expect(target(of: MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot)) == "AF1")
    }

    /// A substitution picks a new bench either way, so queueing behind another
    /// run's print when a hub stands free beside it buys nothing.
    @Test("a substitute prefers a free hub to a queued one")
    func substitutePrefersAFreeHub() {
        let snapshot = world(
            shortFleet() + [
                bench("AF1", status: "idle", location: awayLocation),
                bench("AF2", status: "printing (ftl_relay)"), bench("AF7", status: "idle"),
            ],
            busy: openPrint(on: "AF2")
        )

        #expect(target(of: MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot)) == "AF7")
    }

    /// With every bench at the depot already AT capacity there is no bench to
    /// choose — never the lowest-coded busy one. `queueSize: 1` makes the
    /// capacity explicit rather than an accident of an unset default.
    @Test("with every hub queued there is no bench to choose")
    func allHubsQueuedYieldsNoBench() {
        var busy = openPrint(on: "AF2")
        busy.merge(openPrint(on: "AF7")) { _, last in last }
        let snapshot = world(
            shortFleet() + [
                bench("AF1", status: "idle", location: awayLocation),
                bench("AF2", status: "printing (ftl_relay)", queueSize: 1),
                bench("AF7", status: "printing (mining_drone)", queueSize: 1),
            ],
            busy: busy
        )

        let directive = run(hub: "AF1")
        let ctx = StepContext(directive: directive, world: snapshot, step: directive.step)
        let order = PrintOrder(deviceType: "mining_drone", owner: directive.id)

        #expect(PrintJob(depot: depot).bench(ctx, for: order) == nil)
    }

    /// With the bench empty of anything able there is nothing to substitute, and
    /// the run escalates rather than re-collecting the server's refusal forever.
    @Test("a compacted hub with no able sibling stalls")
    func noSubstituteStalls() {
        let snapshot = world(shortFleet() + [bench("AF1", status: "compacted")])

        #expect(MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot) == .stall(.unreachableDevice))
    }

    /// A carrier hull advertises `enqueue_print`, and printing the fleet into the
    /// vehicle meant to carry it is not a substitution the run may make.
    @Test("a carrier hull is not a substitute printer")
    func carrierHullIsNotASubstitute() {
        let hull = device(
            "SC2", type: MineRecipe.carrierDeviceType,
            features: ["cradle", "surge"], commands: ["enqueue_print"]
        )
        let snapshot = world(shortFleet() + [bench("AF1", status: "compacted"), hull])

        #expect(MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot) == .stall(.unreachableDevice))
    }

    /// An unstamped row has only its pinned hub to name the bench, so it goes on
    /// behaving exactly as it did before the depot became the anchor.
    @Test("an unstamped row still resolves through its own hub")
    func unstampedRowResolvesThroughItsHub() {
        let snapshot = world(shortFleet() + [bench("AF1", status: "idle")])

        let action = MineFleetPrint().nextAction(directive: run(hub: "AF1", depot: nil), world: snapshot)

        #expect(target(of: action) == "AF1")
    }

    /// Nothing to resolve through at all is the original escalation, unchanged.
    @Test("a hub gone from the fleet still stalls")
    func missingHubStillStalls() {
        let snapshot = world(shortFleet())

        #expect(MineFleetPrint().nextAction(directive: run(hub: "AF1"), world: snapshot) == .stall(.unreachableDevice))
    }
}

@Suite("Device.acceptsPrintJobs")
struct AcceptsPrintJobsTests {

    @Test(
        "a hub refuses jobs while packed, under way, stowed or out of range",
        arguments: ["compacted", "travelling", "cruising", "surging", "stowed", "out_of_range"]
    )
    func refusingStatuses(status: String) {
        #expect(bench("AF1", status: status).acceptsPrintJobs == false)
    }

    @Test(
        "a hub takes jobs while idle or already printing",
        arguments: ["idle", "printing (ftl_relay)"]
    )
    func acceptingStatuses(status: String) {
        #expect(bench("AF1", status: status).acceptsPrintJobs)
    }

    /// The status gate never promotes a device that could not print in the first
    /// place, so capability stays the first clause.
    @Test("a device without the command never accepts a job")
    func capabilityStillGates() {
        #expect(device("D1", type: "mining_drone").acceptsPrintJobs == false)
    }

    /// A component printer advertises `enqueue_print` and is consumed by the
    /// print that needs it, after which the server answers a job against it
    /// with "Not your device". Capability alone must not make it a bench.
    @Test(
        "a component printer advertising the command is still not a bench",
        arguments: ["structural_fabricator", "orbital_foundry", "heaven_vessel"]
    )
    func componentPrintersAreNotBenches(type: String) {
        let printer = device("C1", type: type, status: "idle", commands: ["enqueue_print"])
        #expect(printer.isPrintHub)
        #expect(printer.acceptsPrintJobs == false)
    }
}
