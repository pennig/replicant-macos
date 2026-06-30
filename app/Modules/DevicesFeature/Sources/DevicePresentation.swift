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
    /// "heaven_vessel" → "Heaven Vessel".
    static func displayName(_ deviceType: String) -> String {
        deviceType
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A dispatchable command surfaced in the inspector's grid. Only commands
/// `CommandClient` implements map here; the rest of a device's
/// `available_commands` are skipped. Parameterized commands (travel/mine/print)
/// reveal an inline panel; everything else is a confirm-only action.
enum DeviceCommand: Hashable, Identifiable {
    case travel
    case mine
    case retarget
    case scan
    case census
    case print
    case stow
    /// A parameter-less lifecycle command, by backend verb (e.g. `deactivate`).
    case simple(String)

    var id: String { backendCommand }

    init?(command: String) {
        switch command {
        case "travel":         self = .travel
        case "start_mining":   self = .mine
        case "retarget":       self = .retarget
        case "system_scan":    self = .scan
        case "stellar_census": self = .census
        case "enqueue_print":  self = .print
        case "stow":           self = .stow
        default:
            // Surface only the parameter-less commands CommandClient can dispatch.
            guard CommandClient.supportedSimpleCommands.contains(command) else { return nil }
            self = .simple(command)
        }
    }

    /// The backend `available_commands` string this maps to.
    var backendCommand: String {
        switch self {
        case .travel:        return "travel"
        case .mine:          return "start_mining"
        case .retarget:      return "retarget"
        case .scan:          return "system_scan"
        case .census:        return "stellar_census"
        case .print:         return "enqueue_print"
        case .stow:          return "stow"
        case let .simple(c): return c
        }
    }

    var kind: OperationKind {
        switch self {
        case .travel:        return .travel
        case .mine:          return .mine
        case .retarget:      return .retarget
        case .scan:          return .scan
        case .census:        return .census
        case .print:         return .print
        case .stow:          return .stow
        case let .simple(c): return .simple(c)
        }
    }

    var title: String {
        switch self {
        case .travel:        return "Travel"
        case .mine:          return "Mine"
        case .retarget:      return "Retarget"
        case .scan:          return "Scan"
        case .census:        return "Census"
        case .print:         return "Print"
        case .stow:          return "Stow"
        case let .simple(c): return DevicePresentation.displayName(c)
        }
    }

    var systemImage: String {
        switch self {
        case .travel:        return "location.north.line"
        case .mine:          return "hammer"
        case .retarget:      return "scope"
        case .scan:          return "dot.radiowaves.up.forward"
        case .census:        return "list.star"
        case .print:         return "printer"
        case .stow:          return "archivebox"
        case let .simple(c): return Self.simpleSymbols[c] ?? "bolt"
        }
    }

    private static let simpleSymbols: [String: String] = [
        "activate": "bolt", "deactivate": "bolt.slash",
        "deploy": "arrow.up.forward.app", "recall": "arrow.uturn.backward",
        "decommission": "trash", "clear_queue": "trash.slash",
        "clear_directive": "xmark.circle", "assemble": "square.stack.3d.up",
        "compact": "arrow.down.right.and.arrow.up.left", "launch": "paperplane",
        "unfurl": "arrow.up.left.and.arrow.down.right", "withdraw": "tray.and.arrow.down",
        "search": "magnifyingglass", "set_entry_point": "mappin.and.ellipse",
        "detonate": "burst",
    ]

    /// Whether firing this command warrants a danger-styled confirm.
    var isDestructive: Bool {
        switch self {
        case let .simple(c): return c == "decommission" || c == "detonate"
        default:             return false
        }
    }

    /// What the inline panel collects before confirming.
    enum Parameter: Hashable {
        case text(label: String, placeholder: String)
        case choice(label: String, options: [String])
        case none
    }

    var parameter: Parameter {
        switch self {
        case .travel:          return .text(label: "Destination", placeholder: "ATIANFU-1")
        case .print:           return .text(label: "Device type", placeholder: "ftl_beacon")
        case .mine, .retarget: return .choice(label: "Resource", options: Self.miningResources)
        case .scan, .census, .stow, .simple: return .none
        }
    }

    /// The `resource_type` values `start_mining` / `retarget` accept.
    static let miningResources = ["structural", "conductive", "silicates", "carbon", "volatiles", "rares"]

    func params(_ value: String) -> CommandParams {
        switch self {
        case .travel:          return CommandParams(destination: value)
        case .print:           return CommandParams(deviceType: value)
        case .mine, .retarget: return CommandParams(resourceType: value)
        case .scan, .census, .stow, .simple: return CommandParams()
        }
    }
}
