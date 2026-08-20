//
//  DeviceOperations.swift
//  Replicould — DevicesFeature
//
//  Which of a device's live operations the detail card shows, and how many
//  are waiting behind it.
//

import Foundation
import GameModels

enum DeviceOperations {
    /// The job the card should show: what the device is doing now, or the
    /// oldest thing it is about to do.
    static func card(for deviceCode: String, in operations: [GameModels.Operation]) -> GameModels.Operation? {
        let open = open(for: deviceCode, in: operations)
        return open.first { $0.status == .active } ?? open.first
    }

    /// How many of the device's `liveCases` operations wait behind the card's
    /// — an `optimistic` dispatch doesn't count until the server confirms it.
    static func queuedBehind(for deviceCode: String, in operations: [GameModels.Operation]) -> Int {
        let count = operations
            .filter { $0.entityCode == deviceCode && OperationStatus.liveCases.contains($0.status) }
            .count
        return max(0, count - 1)
    }

    private static func open(for deviceCode: String, in operations: [GameModels.Operation]) -> [GameModels.Operation] {
        operations
            .filter { $0.entityCode == deviceCode && $0.status.isOpen }
            .sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
    }
}
