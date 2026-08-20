//
//  PrintSchedulerTests.swift
//  Replicould — DirectiveEngine
//
//  Which benches a depot has, how deep each one is, and which one takes the
//  next job.
//

import Foundation
import GameModels
import Testing
import Utils

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let depot = "AINALRAM-BELT-1"
private let elsewhere = "SAGARMADHA"

/// A print-capable device. `queued` names the device types waiting in its
/// `print_queue`; `printing` names the type on the platen right now.
private func bench(
    _ code: String, type: String = "autofactory", status: String = "idle",
    location: String? = depot, features: [String] = [],
    commands: [String] = ["enqueue_print"], capacity: Int = 10,
    queued: [String] = [], printing: String? = nil, updatedAt: Date = now
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !queued.isEmpty {
        detail["print_queue"] = .array(queued.map { .object(["device_type": .string($0)]) })
    }
    if let printing {
        detail["printing"] = .object(["device_type": .string(printing)])
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100,
        queueSize: capacity, stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: features, tags: [],
        detail: .object(detail), updatedAt: updatedAt,
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func op(
    on entity: String, owner: String?, status: OperationStatus = .active,
    kind: String = OperationKind.print.rawValue,
    deviceType: String? = nil, quantity: Int? = nil,
    id: String? = nil, startedAt: Date = now
) -> GameModels.Operation {
    var params: [String: JSONValue] = [:]
    if let deviceType { params["device_type"] = .string(deviceType) }
    if let quantity { params["quantity"] = .number(Double(quantity)) }
    return GameModels.Operation(
        id: id ?? "OP-\(entity)", entityCode: entity, kind: kind,
        status: status, source: .poll, startedAt: startedAt, completesAt: nil,
        lastConfirmedAt: startedAt, detail: .object(["params": .object(params)]),
        directiveID: owner
    )
}

/// `queued` defaults each `open` op into its own single-entry queue, mirroring
/// `WorldSnapshot.read`'s real shape; pass `queued` explicitly for a bench
/// carrying more than one live op.
private func snapshot(
    _ devices: [Device], open: [String: GameModels.Operation] = [:],
    queued: [String: [GameModels.Operation]] = [:]
) -> WorldSnapshot {
    var allQueued = queued
    for (code, op) in open where allQueued[code] == nil {
        allQueued[code] = [op]
    }
    return WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: open, queuedOperations: allQueued, dispatchedOperations: [:], now: now
    )
}

@Suite("Print scheduler — benches")
struct PrintSchedulerBenchTests {

    @Test("a depot's benches are its print-capable devices, lowest code first")
    func benchesAreCapableDevicesInCodeOrder() {
        let world = snapshot([
            bench("B3"), bench("B1"), bench("B2"),
            bench("X1", commands: []),                    // not print-capable
            bench("X2", location: elsewhere),             // wrong depot
            bench("X3", features: ["cradle", "surge"]),   // a carrier hull
            bench("X4", status: "compacted")              // refuses jobs
        ])

        #expect(
            PrintScheduler.benches(at: depot, in: world).map(\.device.deviceCode)
                == ["B1", "B2", "B3"]
        )
    }

    /// The active job is NOT a `print_queue` entry — it lives in its own
    /// `printing` block — so depth is the queue plus one when the platen is busy.
    @Test("depth counts the active job and the waiting queue")
    func depthCountsActiveAndQueued() {
        let world = snapshot([
            bench("B1", queued: ["mining_drone", "mining_drone"], printing: "ami_transport_controller"),
            bench("B2", queued: ["ftl_relay"]),
            bench("B3", printing: "ftl_relay"),
            bench("B4")
        ])
        let depths = PrintScheduler.benches(at: depot, in: world)
            .reduce(into: [String: Int]()) { $0[$1.device.deviceCode] = $1.queueDepth }

        #expect(depths == ["B1": 3, "B2": 1, "B3": 1, "B4": 0])
    }

    /// `queueSize` is the bench's CAPACITY, never its depth — pinned upstream by
    /// `PrintingSnapshotTests.swift:117-124`. An idle bench advertising ten is empty.
    @Test("an idle bench advertising capacity ten has depth zero")
    func capacityIsNotDepth() {
        let world = snapshot([bench("B1", capacity: 10)])

        #expect(PrintScheduler.benches(at: depot, in: world).first?.queueDepth == 0)
        #expect(PrintScheduler.benches(at: depot, in: world).first?.device.queueSize == 10)
    }

    @Test("owners come from the ops table, never from the queue snapshot")
    func ownersComeFromOps() {
        let world = snapshot(
            [bench("B1", queued: ["mining_drone"]), bench("B2")],
            open: ["B1": op(on: "B1", owner: "D-7")]
        )
        let byCode = PrintScheduler.benches(at: depot, in: world)
            .reduce(into: [String: [String]]()) { $0[$1.device.deviceCode] = $1.owners }

        // B1's queue entry carries no id, so the only owner is the one the op names.
        #expect(byCode == ["B1": ["D-7"], "B2": []])
    }

    @Test("the active job is the bench's live op")
    func activeJobIsTheLiveOp() {
        let mine = op(on: "B1", owner: "D-7")
        let world = snapshot([bench("B1"), bench("B2")], open: ["B1": mine])
        let benches = PrintScheduler.benches(at: depot, in: world)

        #expect(benches.first { $0.device.deviceCode == "B1" }?.activeJob == mine)
        #expect(benches.first { $0.device.deviceCode == "B2" }?.activeJob == nil)
    }

    @Test("a depot with no print-capable device has no benches")
    func noCapableDeviceNoBenches() {
        let world = snapshot([bench("X1", commands: []), bench("X2", location: elsewhere)])

        #expect(PrintScheduler.benches(at: depot, in: world).isEmpty)
    }
}

@Suite("Print scheduler — choosing a bench")
struct PrintSchedulerChoiceTests {
    private func order(_ type: String = "ftl_relay", owner: String = "D-7") -> PrintOrder {
        PrintOrder(deviceType: type, owner: owner)
    }

    @Test("a free bench takes the job, lowest code first")
    func freeBenchLowestCode() {
        let world = snapshot([bench("B2"), bench("B1"), bench("B3")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B1")
    }

    @Test("a busy bench with room still loses to a free one")
    func busyBenchLosesToFree() {
        let world = snapshot(
            [bench("B1", printing: "mining_drone"), bench("B2")],
            open: ["B1": op(on: "B1", owner: "OTHER")]
        )

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    /// Every bench sits AT capacity, not merely busy: this is the case the
    /// depth-ranked `choose` still refuses, unlike a bench with headroom.
    @Test("every bench full yields no choice")
    func everyBenchFullYieldsNil() {
        let world = snapshot([
            bench("B1", capacity: 1, printing: "mining_drone"),
            bench("B2", capacity: 2, queued: ["ftl_relay"], printing: "ftl_relay")
        ])

        #expect(PrintScheduler.choose(order(), at: depot, in: world) == nil)
    }

    /// A queue snapshot with no matching op still adds depth. The operator can
    /// enqueue by hand from the Print Queue screen.
    @Test("a bench queued by hand outranks a free one only by depth")
    func queuedByHandAddsDepth() {
        let world = snapshot([bench("B1", queued: ["ftl_relay"]), bench("B2")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    @Test("a depot with no benches yields no choice")
    func noBenchesYieldsNil() {
        let world = snapshot([bench("X1", commands: [])])

        #expect(PrintScheduler.choose(order(), at: depot, in: world) == nil)
    }
}

@Suite("Print scheduler — queuing behind a busy bench")
struct PrintSchedulerQueueingTests {
    private func order(_ type: String = "ftl_relay", owner: String = "D-7") -> PrintOrder {
        PrintOrder(deviceType: type, owner: owner)
    }

    @Test("with every bench busy, the shallowest queue takes the job")
    func shallowestQueueTakesTheJob() {
        let world = snapshot([
            bench("B1", queued: ["mining_drone", "ftl_relay"], printing: "ami_transport_controller"),
            bench("B2", queued: ["mining_drone"], printing: "ami_transport_controller"),
            bench("B3", queued: ["mining_drone", "ftl_relay", "autofactory"], printing: "ftl_beacon")
        ])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    @Test("equal depth breaks by device code")
    func equalDepthBreaksByCode() {
        let world = snapshot([bench("B2", printing: "mining_drone"), bench("B1", printing: "mining_drone")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B1")
    }

    @Test("a free bench still beats a shallow queue")
    func freeStillBeatsShallow() {
        let world = snapshot([bench("B1", printing: "mining_drone"), bench("B2")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    @Test("a bench at capacity takes nothing")
    func fullBenchTakesNothing() {
        let world = snapshot([bench("B1", capacity: 2, queued: ["mining_drone"], printing: "ami_transport_controller")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world) == nil)
    }

    /// Owners come from `queuedOperations`, oldest first — the active job and
    /// whatever else this bench has enqueued behind it.
    @Test("two runs on one bench are both owners, oldest first")
    func twoOwnersOnOneBench() {
        let older = op(on: "B1", owner: "D-7", startedAt: now)
        let newer = op(
            on: "B1", owner: "D-9", status: .enqueued,
            id: "OP-B1-2", startedAt: now.addingTimeInterval(1)
        )
        let world = snapshot(
            [bench("B1", queued: ["ftl_relay"], printing: "mining_drone")],
            queued: ["B1": [older, newer]]
        )

        #expect(PrintScheduler.benches(at: depot, in: world).first?.owners == ["D-7", "D-9"])
    }

    /// `Device.init`'s `schema.queueSize ?? 0` makes zero the server's own
    /// "never reported" sentinel. Read conservatively — one slot, the platen
    /// only — never as unbounded: most zero-reporting print-capable devices
    /// in the live fleet are vessels and fabricators, not real depots.
    @Test("an unreported queue size still admits an idle bench")
    func unreportedQueueSizeStillAdmitsIdle() {
        let world = snapshot([bench("B1", capacity: 0)])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B1")
    }

    /// Isolated to one bench: if capacity were unbounded, B1's own depth
    /// would still win it the choice, so this proves the CAP, not the rank.
    @Test("an unreported queue size takes nothing more than its platen job")
    func unreportedQueueSizeCapsAtOne() {
        let world = snapshot([bench("B1", capacity: 0, printing: "mining_drone")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world) == nil)
    }

    /// A dispatched op can land before the printer's own poll shows it — the
    /// snapshot alone would read this bench as empty.
    @Test("an op not yet in the queue snapshot still adds depth")
    func opAheadOfItsSnapshotStillAddsDepth() {
        let world = snapshot(
            [bench("B1"), bench("B2")],
            open: ["B1": op(on: "B1", owner: "OTHER")]
        )

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }
}

@Suite("Print scheduler — what is already on order")
struct PrintSchedulerOnOrderTests {

    @Test("an owner's open prints at the depot count, by type and quantity")
    func ownOpenPrintsCount() {
        let world = snapshot(
            [bench("B1"), bench("B2"), bench("B3")],
            open: [
                "B1": op(on: "B1", owner: "D-7", deviceType: "mining_drone", quantity: 3),
                "B2": op(on: "B2", owner: "D-7", deviceType: "ftl_relay", quantity: nil)
            ]
        )

        #expect(
            PrintScheduler.onOrder(for: "D-7", at: depot, in: world)
                == ["mining_drone": 3, "ftl_relay": 1]
        )
    }

    /// `openOperations` holds only the ACTIVE op per device (Task 12); a
    /// second job of the owner's own, still `enqueued` behind it, must not
    /// go uncounted just because it never became the platen job.
    @Test("an owner's own enqueued job behind the active one still counts")
    func ownEnqueuedJobBehindTheActiveOneCounts() {
        let active = op(on: "B1", owner: "D-7", deviceType: "mining_drone", startedAt: now)
        let queued = op(
            on: "B1", owner: "D-7", status: .enqueued, deviceType: "ftl_relay",
            id: "OP-B1-2", startedAt: now.addingTimeInterval(1)
        )
        let world = snapshot([bench("B1")], queued: ["B1": [active, queued]])

        #expect(
            PrintScheduler.onOrder(for: "D-7", at: depot, in: world)
                == ["mining_drone": 1, "ftl_relay": 1]
        )
    }

    /// A job with no quantity is one unit. Written as a literal so that
    /// changing the default reddens this test.
    @Test("a print with no quantity counts as one")
    func missingQuantityIsOne() {
        let world = snapshot(
            [bench("B1")],
            open: ["B1": op(on: "B1", owner: "D-7", deviceType: "ftl_relay")]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world) == ["ftl_relay": 1])
    }

    @Test("another run's print is not ours to net against")
    func coTenantDoesNotCount() {
        let world = snapshot(
            [bench("B1")],
            open: ["B1": op(on: "B1", owner: "OTHER", deviceType: "ftl_relay", quantity: 2)]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world).isEmpty)
    }

    @Test("a print at another depot is not on order here")
    func otherDepotDoesNotCount() {
        let world = snapshot(
            [bench("B1", location: elsewhere)],
            open: ["B1": op(on: "B1", owner: "D-7", deviceType: "ftl_relay")]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world).isEmpty)
    }

    /// An op adopted from a device snapshot carries `detail: {}` — it names no
    /// type. It cannot be netted and must not be counted as a zero.
    @Test("an op that names no device type is not counted")
    func typelessOpNotCounted() {
        let world = snapshot(
            [bench("B1")],
            open: ["B1": op(on: "B1", owner: "D-7")]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world).isEmpty)
    }

    /// A decodable payload is not enough on its own: only print ops are on order.
    @Test("a non-print op does not count, even with a printable payload")
    func nonPrintKindDoesNotCount() {
        let world = snapshot(
            [bench("B1")],
            open: [
                "B1": op(
                    on: "B1", owner: "D-7", kind: OperationKind.mine.rawValue,
                    deviceType: "ftl_relay", quantity: 5
                )
            ]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world).isEmpty)
    }
}
