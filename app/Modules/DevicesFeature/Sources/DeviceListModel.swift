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

/// How a device relates to its host device. The row badges the relationship
/// that did *not* determine its position in the tree, so nothing is lost.
public enum HostRelation: Equatable, Sendable {
    case controlled(by: String)
    case stowed(in: String)
    case attached(to: String)

    public var hostCode: String {
        switch self {
        case let .controlled(code), let .stowed(code), let .attached(code): code
        }
    }

    /// SF Symbol for the badge glyph.
    public var symbol: String {
        switch self {
        case .controlled: "dot.radiowaves.left.and.right"
        case .stowed:     "shippingbox"
        case .attached:   "paperclip"
        }
    }

    public var label: String {
        switch self {
        case let .controlled(code): "Controlled by \(code)"
        case let .stowed(code):     "Stowed in \(code)"
        case let .attached(code):   "Attached to \(code)"
        }
    }
}
