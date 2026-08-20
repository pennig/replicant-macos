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
        let live = live(for: deviceCode, in: operations)
        return live.first { $0.status == .active } ?? live.first
    }

    /// How many of the device's live operations are waiting behind the card's.
    static func queuedBehind(for deviceCode: String, in operations: [GameModels.Operation]) -> Int {
        max(0, live(for: deviceCode, in: operations).count - 1)
    }

    private static func live(for deviceCode: String, in operations: [GameModels.Operation]) -> [GameModels.Operation] {
        operations
            .filter { $0.entityCode == deviceCode && $0.status.isOpen }
            .sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
    }
}
