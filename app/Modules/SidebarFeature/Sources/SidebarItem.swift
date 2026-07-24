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
    case stars, locations, devices, replicants, blueprints, civilisations
    // Missions
    case locationEvents
    // Operations
    case printQueue, operationsLog
    // Comms
    case messages, bobnet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stars: "Stars"
        case .locations: "Locations"
        case .devices: "Devices"
        case .replicants: "Replicants"
        case .blueprints: "Blueprints"
        case .civilisations: "Civilisations"
        case .locationEvents: "Location Events"
        case .printQueue: "Printing"
        case .operationsLog: "Operations Log"
        case .messages: "Messages"
        case .bobnet: "Bobnet"
        }
    }

    public var symbol: String {
        switch self {
        case .stars: "sparkles"
        case .locations: "map"
        case .devices: "circle.hexagongrid"
        case .replicants: "point.3.connected.trianglepath.dotted"
        case .blueprints: "doc.plaintext"
        case .civilisations: "person.2.wave.2"
        case .locationEvents: "flag"
        case .printQueue: "printer"
        case .operationsLog: "list.bullet.rectangle"
        case .messages: "envelope"
        case .bobnet: "bubble.left.and.bubble.right"
        }
    }

    /// Some categories show content only — no detail pane (Galaxy Map and the
    /// live Operations Log ledger).
    public var hasDetail: Bool {
        switch self {
        case .operationsLog, .stars: false
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
        Group(id: "Catalog", items: [.stars, .locations, .devices, .replicants, .blueprints, .civilisations]),
        Group(id: "Missions", items: [.locationEvents]),
        Group(id: "Operations", items: [.printQueue, .operationsLog]),
        Group(id: "Comms", items: [.messages, .bobnet]),
    ]
}
