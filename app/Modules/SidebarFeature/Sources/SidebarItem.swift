//
//  SidebarItem.swift
//  Replicould — Sidebar feature
//
//  The categories shown in the sidebar, grouped into three sections. Public so
//  the app's `MainView` can switch its content/detail panes on the current
//  selection (owned by `SidebarFeature`).
//

import Foundation

/// The categories shown in the sidebar, grouped into three sections.
public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Catalog
    case stars, locations, devices, replicants, blueprints
    // Operations
    case printQueue
    // Comms
    case messages, bobnet, eventLog

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stars: "Stars"
        case .locations: "Locations"
        case .devices: "Devices"
        case .replicants: "Replicants"
        case .blueprints: "Blueprints"
        case .printQueue: "Print Queue"
        case .messages: "Messages"
        case .bobnet: "Bobnet"
        case .eventLog: "Event Log"
        }
    }

    public var symbol: String {
        switch self {
        case .stars: "sparkles"
        case .locations: "map"
        case .devices: "circle.hexagongrid"
        case .replicants: "point.3.connected.trianglepath.dotted"
        case .blueprints: "doc.plaintext"
        case .printQueue: "printer"
        case .messages: "envelope"
        case .bobnet: "bubble.left.and.bubble.right"
        case .eventLog: "list.bullet.rectangle"
        }
    }

    /// Some categories show content only — no detail pane (Galaxy Map, Bobnet,
    /// and the live Event Log ledger).
    public var hasDetail: Bool {
        switch self {
        case .eventLog, .stars, .bobnet: false
        default: true
        }
    }

    /// Placeholder content rows for this category.
    public var sampleItems: [String] {
        (1...8).map { "\(title) item \($0)" }
    }

    public struct Group: Identifiable, Sendable {
        public let id: String
        public let items: [SidebarItem]
    }

    public static let groups: [Group] = [
        Group(id: "Catalog", items: [.stars, .locations, .devices, .replicants, .blueprints]),
        Group(id: "Operations", items: [.printQueue]),
        Group(id: "Comms", items: [.messages, .bobnet, .eventLog]),
    ]
}
