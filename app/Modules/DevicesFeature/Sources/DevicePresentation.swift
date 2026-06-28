//
//  DevicePresentation.swift
//  Replicould — Devices feature
//
//  View-side helpers that map backend strings to display: a device-type glyph
//  and human name, and which of a device's `available_commands` the inspector
//  can actually dispatch (travel / print today) and how they're parameterized.
//

import DependencyClients
import Foundation

enum DevicePresentation {
    /// An SF Symbol for a device type.
    static func symbol(for deviceType: String) -> String {
        switch deviceType {
        case "heaven_vessel":     return "paperplane"
        case "replicant_matrix":  return "square.grid.2x2"
        case "mining_drone":      return "hammer"
        case "survey_drone":      return "scope"
        case "transport_hauler":  return "shippingbox"
        case "maintenance_drone": return "wrench.and.screwdriver"
        case "ftl_beacon":        return "antenna.radiowaves.left.and.right"
        default:                  return "circle.hexagongrid"
        }
    }

    /// "heaven_vessel" → "Heaven Vessel".
    static func displayName(_ deviceType: String) -> String {
        deviceType
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A dispatchable command surfaced in the inspector's grid. Only the commands
/// `CommandClient` implements appear as actionable; the rest are shown disabled.
enum DeviceCommand: Hashable, Identifiable {
    case travel
    case print

    var id: Self { self }

    init?(command: String) {
        switch command {
        case "travel":        self = .travel
        case "enqueue_print": self = .print
        default:              return nil
        }
    }

    var kind: OperationKind {
        switch self {
        case .travel: return .travel
        case .print:  return .print
        }
    }

    var title: String {
        switch self {
        case .travel: return "Travel"
        case .print:  return "Print"
        }
    }

    var systemImage: String {
        switch self {
        case .travel: return "location.north.line"
        case .print:  return "printer"
        }
    }

    /// What the inline panel collects.
    enum Parameter { case destination, deviceType }
    var parameter: Parameter {
        switch self {
        case .travel: return .destination
        case .print:  return .deviceType
        }
    }

    var parameterLabel: String {
        switch parameter {
        case .destination: return "Destination"
        case .deviceType:  return "Device type"
        }
    }

    var parameterPlaceholder: String {
        switch parameter {
        case .destination: return "ATIANFU-1"
        case .deviceType:  return "ftl_beacon"
        }
    }

    func params(_ value: String) -> CommandParams {
        switch parameter {
        case .destination: return CommandParams(destination: value)
        case .deviceType:  return CommandParams(deviceType: value)
        }
    }
}
