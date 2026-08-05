//
//  DeviceListModel.swift
//  Replicould — Devices feature
//
//  The value types `DeviceListLayout` returns. Pure data plus display labels;
//  no SwiftUI, no logic. The view renders these and nothing else.
//

import Foundation
import GameModels

/// Why a device is in the Needs Attention section. A device can carry several.
public enum AttentionFlag: Equatable, Sendable {
    /// Operational capacity below `DeviceListLayout.damagedCapacityThreshold`.
    case damaged(capacity: Double)
    /// `detail.in_control_range == false` — cut off from its AMI controller.
    case outOfControlRange
    /// A directive in `needsAttention` covers this device. The reason is
    /// optional because `Directive.attentionReason` is nullable: a directive can
    /// be flagged without a recorded reason, and the device still needs a look.
    case directive(DirectiveAttentionReason?)

    /// The short label the row shows. The directive case reuses the existing
    /// `DirectiveAttentionReason` display text rather than inventing new copy.
    public var label: String {
        switch self {
        case let .damaged(capacity):
            "Damaged · \(Int(capacity.rounded()))%"
        case .outOfControlRange:
            "Out of control range"
        case let .directive(reason):
            reason?.displayName ?? "Directive needs attention"
        }
    }
}
