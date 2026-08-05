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

/// One visible row. `depth` is a rendering hint on an already-flattened array —
/// nothing recurses in the view.
public struct DeviceEntry: Identifiable, Equatable, Sendable {
    public var device: Device
    /// Indent level, clamped at `DeviceListLayout.maxIndentDepth`.
    public var depth: Int
    /// Number of children this row hosts. 0 ⇒ not a host, so no chevron.
    /// While a search query is active this counts *retained* children only.
    public var childCount: Int
    public var isExpanded: Bool
    /// The relationship badge — the containment relation that did not decide
    /// this row's position.
    public var host: HostRelation?
    /// The device type of the host named by `host` — e.g. `ami_transport_controller`
    /// for a device controlled by one. Nil when `host` is nil, or when the host
    /// is unresolved (a promoted device badging a host that isn't in the
    /// fleet). Resolved by `DeviceListLayout.flatten` from a code→type map, not
    /// looked up here — this type stays a pure value, no fleet to walk.
    public var hostDeviceType: String?
    public var attention: [AttentionFlag]

    public var id: String { device.deviceCode }

    public init(
        device: Device,
        depth: Int,
        childCount: Int,
        isExpanded: Bool,
        host: HostRelation?,
        hostDeviceType: String?,
        attention: [AttentionFlag]
    ) {
        self.device = device
        self.depth = depth
        self.childCount = childCount
        self.isExpanded = isExpanded
        self.host = host
        self.hostDeviceType = hostDeviceType
        self.attention = attention
    }
}

/// One segment of a section header's status-distribution bar.
public struct StatusShare: Identifiable, Equatable, Sendable {
    /// The raw `statusBase`, mapped to a colour by `DeviceStatus.tone(for:)`.
    public var status: String
    public var count: Int
    public var id: String { status }

    public init(status: String, count: Int) {
        self.status = status
        self.count = count
    }
}

/// A section's readout header. Nil on an unheadered section.
public struct DeviceListHeader: Equatable, Sendable {
    public var title: String
    /// The whole population this header describes — every device under it,
    /// roots and carried-along descendants alike. Matches `statusShares`'
    /// total and the row count a reader sees on opening the section, so the
    /// header and the composition bar it sits beside never disagree about
    /// what's being summarised.
    public var count: Int
    public var isCollapsed: Bool
    /// The section's status distribution, count descending then status name —
    /// what makes a collapsed section still worth reading.
    public var statusShares: [StatusShare]
    /// Any member below `DeviceListLayout.damagedCapacityThreshold`.
    public var hasDamaged: Bool

    public init(
        title: String,
        count: Int,
        isCollapsed: Bool,
        statusShares: [StatusShare],
        hasDamaged: Bool
    ) {
        self.title = title
        self.count = count
        self.isCollapsed = isCollapsed
        self.statusShares = statusShares
        self.hasDamaged = hasDamaged
    }
}

/// A section of already-flattened rows. Real `Section`s (rather than one wholly
/// flat array) are what let the list keep `pinnedViews: [.sectionHeaders]` and
/// its sticky Liquid Glass headers.
public struct DeviceListSection: Identifiable, Equatable, Sendable {
    public static let attentionID = "attention"
    public static let fleetID = "all"

    public var id: String
    /// Nil ⇒ unheadered (the Carrier-mode fleet section).
    public var header: DeviceListHeader?
    /// Already flattened; empty when the section is collapsed.
    public var entries: [DeviceEntry]

    public init(id: String, header: DeviceListHeader?, entries: [DeviceEntry]) {
        self.id = id
        self.header = header
        self.entries = entries
    }
}

extension Array where Element == DeviceListSection {
    /// The list's flat, top-to-bottom row order — what drives arrow-key
    /// navigation. A collapsed host contributes no entries, so hidden rows are
    /// absent by construction rather than by a second rule that could drift.
    public var orderedIDs: [String] { flatMap(\.entries).map(\.id) }
}
