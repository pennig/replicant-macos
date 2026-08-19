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
                let active = world.openOperation(for: device.deviceCode)
                return Bench(
                    device: device,
                    activeJob: active,
                    queueDepth: depth(of: device),
                    owners: [active?.directiveID].compactMap { $0 }
                )
            }
    }

    /// The bench's load: the waiting queue plus the job on the platen.
    /// The two live in different blocks and never overlap, and `queueSize` is
    /// the bench's capacity rather than its load.
    private static func depth(of device: Device) -> Int {
        device.queuedJobCount + (device.printingSnapshot != nil ? 1 : 0)
    }

    /// The bench that should take `order` at `depot`, or nil when none can.
    /// Phase A takes only an idle bench: dispatching onto an occupied one
    /// supersedes whatever op it already holds, so Task 14 relaxes this to depth.
    static func choose(_ order: PrintOrder, at depot: String, in world: WorldSnapshot) -> Bench? {
        benches(at: depot, in: world).first { $0.queueDepth == 0 && $0.activeJob == nil }
    }

    /// What `owner` already has on order at `depot`, by device type. Ops only:
    /// a `print_queue` entry carries no id, so it cannot be attributed to a
    /// directive; an op that names no type cannot be netted.
    static func onOrder(
        for owner: String, at depot: String, in world: WorldSnapshot
    ) -> [String: Int] {
        let codes = Set(benches(at: depot, in: world).map(\.device.deviceCode))
        return world.openOperations.values.reduce(into: [String: Int]()) { total, op in
            guard op.kind == OperationKind.print.rawValue,
                  op.directiveID == owner,
                  codes.contains(op.entityCode),
                  let type = op.printedDeviceType
            else { return }
            total[type, default: 0] += op.printedQuantity ?? 1
        }
    }
}
