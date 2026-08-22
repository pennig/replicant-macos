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
                let open = openOps(for: device.deviceCode, in: world)
                return Bench(
                    device: device,
                    activeJob: open.first { $0.status == .active },
                    queueDepth: depth(of: device, ops: open),
                    owners: open.compactMap(\.directiveID)
                )
            }
    }

    /// This bench's open ops, oldest first: `queuedOperations` when populated,
    /// else a one-op fallback onto `openOperations` (which it always subsumes
    /// in a real read).
    private static func openOps(for deviceCode: String, in world: WorldSnapshot) -> [GameModels.Operation] {
        let queued = world.queuedOperations[deviceCode] ?? []
        return queued.isEmpty ? world.openOperation(for: deviceCode).map { [$0] } ?? [] : queued
    }

    /// The bench's load: the printer's own snapshot, or the ops table's open
    /// count when that is higher — a dispatch can land before the next poll
    /// reflects it. `queueSize` is capacity, never load.
    private static func depth(of device: Device, ops: [GameModels.Operation]) -> Int {
        max(device.queuedJobCount + (device.printingSnapshot != nil ? 1 : 0), ops.count)
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

    /// What `owner` already has on order at `depot`, by device type: the
    /// greater, per bench, of what its own ops claim and what the bench itself
    /// reports working. The platen belongs to whoever holds the bench's one
    /// active op; a queue entry names nobody, so it counts only on a bench
    /// where every open op is the owner's.
    static func onOrder(
        for owner: String, at depot: String, in world: WorldSnapshot
    ) -> [String: Int] {
        benches(at: depot, in: world).reduce(into: [String: Int]()) { total, bench in
            let live = openOps(for: bench.device.deviceCode, in: world)
                .filter { $0.kind == OperationKind.print.rawValue }
            guard live.contains(where: { $0.directiveID == owner }) else { return }

            var claimed: [String: Int] = [:]
            for op in live where op.directiveID == owner {
                guard let type = op.printedDeviceType else { continue }
                claimed[type, default: 0] += op.printedQuantity ?? 1
            }
            // A batch's jobs 2…N are untyped adopted rows, so only the bench
            // names them. `operation_one_active_per_device` is what makes the
            // platen attributable even when a co-tenant has queued behind.
            var declared: [String: Int] = [:]
            if live.first(where: { $0.status == .active })?.directiveID == owner,
               let platen = bench.device.printingSnapshot?.deviceType
            {
                declared[platen, default: 0] += 1
            }
            if live.allSatisfy({ $0.directiveID == owner }) {
                for (type, count) in queuedJobs(on: bench.device) {
                    declared[type, default: 0] += count
                }
            }
            for type in Set(claimed.keys).union(declared.keys) {
                total[type, default: 0] += max(claimed[type] ?? 0, declared[type] ?? 0)
            }
        }
    }

    /// The bench's own account of what is queued BEHIND the platen, by device
    /// type. A queue entry names no owner, so a caller must establish that
    /// before counting these against anyone.
    private static func queuedJobs(on device: Device) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in device.printQueueItems {
            guard let type = item.deviceType else { continue }
            counts[type, default: 0] += 1
        }
        return counts
    }
}
