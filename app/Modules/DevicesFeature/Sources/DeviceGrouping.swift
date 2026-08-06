//
//  DeviceGrouping.swift
//  Replicould — Devices feature
//
//  Which axis the fleet master list is organised along. Raw values are storage.
//

import Foundation

public enum DeviceGrouping: String, CaseIterable, Identifiable, Sendable {
    /// Nests the containment forest; every other case flattens it.
    case carrier
    case type
    case system
    case mission
    /// Not named `none` — that shadows `Optional.none` at every optional site.
    case flat

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .carrier: "Carrier"
        case .type:    "Type"
        case .system:  "System"
        case .mission: "Mission"
        case .flat:    "Flat"
        }
    }

    public var symbol: String {
        switch self {
        case .carrier: "shippingbox"
        case .type:    "square.grid.2x2"
        case .system:  "circle.hexagongrid"
        case .mission: "tag"
        case .flat:    "list.bullet"
        }
    }
}
