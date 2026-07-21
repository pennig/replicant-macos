//
//  SidebarProgress.swift
//  Replicould — Sidebar feature
//
//  Derives the header's live progress row from the `Operation` table (the same
//  source the device inspector uses), so completion is atomic: the instant the
//  arrival/print event flips the operation to `.completed`, the bar clears —
//  no waiting for the device's live activity block to re-fetch as settled.
//  Kept off the `View` type (a static on a SwiftUI `View` traps under `swift
//  test`) so the derivation is unit-testable.
//

import GameModels
import UI

/// Disambiguate from `Foundation.Operation` (pulled in transitively via UI).
/// Module-internal, so it resolves the bare `Operation` everywhere in the target.
typealias Operation = GameModels.Operation

enum SidebarProgress {
    /// The active replicant's running operation as a header row, or nil when its
    /// host device isn't mid-op. Only the host device counts — the header
    /// represents the replicant itself, so other owned devices' ops (printing,
    /// mining, scanning elsewhere in the fleet) don't drive its progress bar.
    static func active(
        replicant: Replicant,
        devices: [Device],
        operations: [Operation]
    ) -> RCReplicantProgress? {
        guard
            let code = replicant.hostedDeviceCode,
            let host = devices.first(where: { $0.deviceCode == code && $0.replicantCode == replicant.replicantCode }),
            let op = operations.first(where: { $0.entityCode == host.deviceCode && $0.status == .active })
        else { return nil }
        return row(for: host, operation: op)
    }

    /// Distill a device's active operation into a header progress row, or nil when
    /// the op isn't a chartable countdown (not active, or no completion deadline).
    /// Timing comes from the operation; the tint and travel/print labels read the
    /// device row (cosmetic — a briefly-stale device never keeps the bar alive,
    /// since visibility is gated on the operation's status).
    static func row(for device: Device, operation: Operation) -> RCReplicantProgress? {
        guard operation.status == .active, let completesAt = operation.completesAt else { return nil }
        let tint = DeviceStatus.tone(for: device.statusBase).color
        let kind = OperationKind(rawValue: operation.kind)
        let label: String
        let symbol: String?
        if kind == .travel {
            label = operation.travelSnapshot?.destinationLabel
                ?? device.travelSnapshot?.destinationLabel
                ?? device.locationName ?? device.location ?? "In transit"
            symbol = "arrow.right"
        } else if kind == .print {
            label = device.statusParameter.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Printing"
            symbol = "printer"
        } else {
            label = DeviceStatus.label(for: device.statusBase)
            symbol = nil
        }
        return RCReplicantProgress(
            label: label,
            symbol: symbol,
            startedAt: operation.startedAt,
            completesAt: completesAt,
            tint: tint
        )
    }
}
