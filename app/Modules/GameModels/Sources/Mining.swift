//
//  Mining.swift
//  Replicould — shared dependency clients
//
//  A mining drone's `mining` block, mapped to a display value type. Mining is a
//  *continuous* activity with no completion deadline: the drone works the belt in
//  fixed cycles (`cycle_time_seconds`, whose length the belt's density sets — the
//  denser the belt, the more maneuvering between rocks), and each cycle either
//  extracts resource or comes up empty when the resource is scarce. The wire
//  signal for that is the pending tally: after a cycle, `pending_cycles` /
//  `pending_quantity` > 0 means it produced (it's *mining*); both 0 means the last
//  cycle yielded nothing (it's *seeking* a workable pocket). The inspector refreshes
//  the device at each cycle boundary to keep that reading current.
//

import Foundation
import Utils

public struct MiningSnapshot: Equatable, Sendable {
    /// The resource being worked (`structural`, `rares`, …).
    public var resourceType: String?
    /// The belt the drone is mining.
    public var belt: String?
    /// When the current mining operation began (the cycle anchor).
    public var startedAt: Date?
    /// Seconds per mining cycle — set by belt density, not the deadline of the op.
    public var cycleTimeSeconds: Double?
    /// Completed cycles whose yield hasn't been collected yet.
    public var pendingCycles: Int?
    /// Uncollected resource quantity accrued so far.
    public var pendingQuantity: Double?
    /// How plentiful the resource is (`abundant` / `scarce` / …) — governs yield.
    public var availability: String?
    /// Belt density (`sparse` / `dense` / …) — governs cycle length.
    public var density: String?

    public init(
        resourceType: String? = nil,
        belt: String? = nil,
        startedAt: Date? = nil,
        cycleTimeSeconds: Double? = nil,
        pendingCycles: Int? = nil,
        pendingQuantity: Double? = nil,
        availability: String? = nil,
        density: String? = nil
    ) {
        self.resourceType = resourceType
        self.belt = belt
        self.startedAt = startedAt
        self.cycleTimeSeconds = cycleTimeSeconds
        self.pendingCycles = pendingCycles
        self.pendingQuantity = pendingQuantity
        self.availability = availability
        self.density = density
    }

    /// Whether the drone is actively extracting rather than seeking. A cycle that
    /// yields resource leaves a positive pending tally; a scarce belt that turns up
    /// nothing leaves both at 0. This is the mining-vs-seeking discriminator the
    /// card renders, refreshed each cycle.
    public var isProducing: Bool { (pendingCycles ?? 0) > 0 || (pendingQuantity ?? 0) > 0 }
}

extension MiningSnapshot {
    /// Parse from a device's `mining` block. Nil when the value isn't an object
    /// (the device isn't mining).
    public init?(miningBlock value: JSONValue?) {
        guard case .object = value else { return nil }
        self.init(
            resourceType: value?["resource_type"]?.stringValue,
            belt: value?["belt"]?.stringValue,
            startedAt: value?["started_at"]?.stringValue.flatMap(DiversionSnapshot.parseDate),
            cycleTimeSeconds: value?["cycle_time_seconds"]?.numberValue,
            pendingCycles: value?["pending_cycles"]?.numberValue.map(Int.init),
            pendingQuantity: value?["pending_quantity"]?.numberValue,
            availability: value?["availability"]?.stringValue,
            density: value?["density"]?.stringValue
        )
    }
}

extension Device {
    /// The drone's live mining state, parsed from its `mining` block. Nil when the
    /// device carries no mining block.
    public var miningSnapshot: MiningSnapshot? {
        MiningSnapshot(miningBlock: detail["mining"])
    }
}
