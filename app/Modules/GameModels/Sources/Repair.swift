//
//  Repair.swift
//  Replicould — shared dependency clients
//
//  A repair drone / service bot's `repair` block, mapped to a display value type.
//  Repair is a *finite* in-place task: the bot works on a single target device
//  (`target_device_code`), the server reports how far along it is
//  (`progress_percent`, authoritative) and how much longer it has (`eta_seconds`,
//  remaining from the read). Unlike travel/print the payload carries no absolute
//  `completes_at`, so the deadline is derived from the read event-time plus the
//  remaining ETA (mirroring the survey `scan` block). The inspector refreshes the
//  device while it's in view so the progress and target stay current.
//

import Foundation
import Utils

public struct RepairSnapshot: Equatable, Sendable {
    /// The device being repaired (`304F6EC1`).
    public var targetDeviceCode: String?
    /// When the repair began — the anchor for the live progress bar.
    public var startedAt: Date?
    /// How far along the repair is (0…100), server-authoritative.
    public var progressPercent: Double?
    /// When the repair is projected to finish, derived from the read event-time
    /// plus the remaining `eta_seconds`. Nil when the block carried no ETA.
    public var completesAt: Date?

    public init(
        targetDeviceCode: String? = nil,
        startedAt: Date? = nil,
        progressPercent: Double? = nil,
        completesAt: Date? = nil
    ) {
        self.targetDeviceCode = targetDeviceCode
        self.startedAt = startedAt
        self.progressPercent = progressPercent
        self.completesAt = completesAt
    }
}

extension RepairSnapshot {
    /// Parse from a device's `repair` block. `anchor` is the read event-time the
    /// remaining `eta_seconds` is measured from (the device's `updatedAt`), so the
    /// derived `completesAt` lands on the real finish. Nil when the value isn't an
    /// object (the device isn't repairing).
    public init?(repairBlock value: JSONValue?, anchoredAt anchor: Date) {
        guard case .object = value else { return nil }
        let eta = value?["eta_seconds"]?.numberValue
        self.init(
            targetDeviceCode: value?["target_device_code"]?.stringValue,
            startedAt: value?["started_at"]?.stringValue.flatMap(DiversionSnapshot.parseDate),
            progressPercent: value?["progress_percent"]?.numberValue,
            completesAt: eta.map { anchor.addingTimeInterval($0) }
        )
    }
}

extension Device {
    /// The bot's live repair state, parsed from its `repair` block. The remaining
    /// ETA is anchored on `updatedAt` (the read event-time) so the projected
    /// completion is honest. Nil when the device carries no repair block.
    public var repairSnapshot: RepairSnapshot? {
        RepairSnapshot(repairBlock: detail["repair"], anchoredAt: updatedAt)
    }
}
