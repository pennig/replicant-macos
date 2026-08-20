//
//  PrintScheduler.swift
//  Replicould — DirectiveEngine
//
//  Which benches a depot has, how deep each one is, and which one takes the
//  next job. The one place any mission decides where a print goes.
//

import GameModels

/// One print-capable device at a depot, with what it is carrying.
/// `queueDepth` comes from the printer's own snapshot; `owners` can only come
/// from the ops table, because a queue entry carries no id.
struct Bench: Equatable, Sendable {
    let device: Device
    let activeJob: GameModels.Operation?
    let queueDepth: Int
    let owners: [String]
}

/// What a short reserve rail does to the run that wanted the print.
enum RailPolicy: Equatable, Sendable {
    case wait
    case stall(DirectiveAttentionReason)
}

/// One job a mission wants printed, and what it wants done if the rail is short.
struct PrintOrder: Equatable, Sendable {
    let deviceType: String
    let quantity: Int?
    let tags: [FleetTag]
    /// The directive id the op row is stamped with.
    let owner: String
    let onRailShort: RailPolicy

    init(
        deviceType: String, quantity: Int? = nil, tags: [FleetTag] = [],
        owner: String, onRailShort: RailPolicy = .wait
    ) {
        self.deviceType = deviceType
        self.quantity = quantity
        self.tags = tags
        self.owner = owner
        self.onRailShort = onRailShort
    }
}

enum PrintScheduler {

    /// Every bench standing at `depot`, lowest device code first.
    /// A carrier hull is excluded even when it advertises the command: printing
    /// into a vessel a run is about to fly away is a job that leaves with it.
    static func benches(at depot: String, in world: WorldSnapshot) -> [Bench] {
        world.devices.values
            .filter { $0.acceptsPrintJobs && $0.location == depot && !$0.isCarrierHull }
            .sorted { $0.deviceCode < $1.deviceCode }
            .map { device in
                let live = liveOps(for: device.deviceCode, in: world)
                return Bench(
                    device: device,
                    activeJob: live.first { $0.status == .active },
                    queueDepth: depth(of: device, liveOps: live),
                    owners: live.compactMap(\.directiveID)
                )
            }
    }

    /// This bench's live ops, oldest first: `queuedOperations` when populated,
    /// else a one-op fallback onto `openOperations` (which it always subsumes
    /// in a real read).
    private static func liveOps(for deviceCode: String, in world: WorldSnapshot) -> [GameModels.Operation] {
        let queued = world.queuedOperations[deviceCode] ?? []
        return queued.isEmpty ? world.openOperation(for: deviceCode).map { [$0] } ?? [] : queued
    }

    /// The bench's load: the printer's own snapshot, or the ops table's live
    /// count when that is higher — a dispatch can land before the next poll
    /// reflects it. `queueSize` is capacity, never load.
    private static func depth(of device: Device, liveOps: [GameModels.Operation]) -> Int {
        max(device.queuedJobCount + (device.printingSnapshot != nil ? 1 : 0), liveOps.count)
    }

    /// The bench that should take `order` at `depot`, or nil when none can.
    /// A free bench beats a shallow queue, a shallow queue beats a deep one,
    /// and the lowest device code breaks every tie.
    static func choose(_ order: PrintOrder, at depot: String, in world: WorldSnapshot) -> Bench? {
        benches(at: depot, in: world)
            .filter { $0.queueDepth < capacity(of: $0.device) }
            .min { left, right in
                left.queueDepth == right.queueDepth
                    ? left.device.deviceCode < right.device.deviceCode
                    : left.queueDepth < right.queueDepth
            }
    }

    /// `queueSize` reads 0 when the server never reported it (`Device.init`'s
    /// `?? 0`); read conservatively as ONE slot — the platen only, nothing
    /// queued behind it — never as unbounded.
    private static func capacity(of device: Device) -> Int {
        device.queueSize > 0 ? device.queueSize : 1
    }

    /// What `owner` already has on order at `depot`, by device type — every
    /// live op per bench, not just the active one. A `print_queue` entry
    /// carries no id, so only ops can be attributed to a directive.
    static func onOrder(
        for owner: String, at depot: String, in world: WorldSnapshot
    ) -> [String: Int] {
        benches(at: depot, in: world).reduce(into: [String: Int]()) { total, bench in
            for op in liveOps(for: bench.device.deviceCode, in: world) {
                guard op.kind == OperationKind.print.rawValue,
                      op.directiveID == owner,
                      let type = op.printedDeviceType
                else { continue }
                total[type, default: 0] += op.printedQuantity ?? 1
            }
        }
    }
}
