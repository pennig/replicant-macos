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
import GameModels

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
    /// Survey-drone body scan (`scan` verb) — a long-running scan of the body at
    /// the drone's location, distinct from the heaven-vessel `system_scan`.
    case surveyScan
    case census
    case print
    case stow
    /// Set an AMI controller's directive, chosen from the device's
    /// `available_directives` (threaded in at construction since the vocabulary is
    /// per-device).
    case setDirective(available: [String])
    /// Adopt worker devices under an AMI controller, chosen from the fleet's
    /// eligible candidates (threaded in at construction, like `setDirective`).
    case adopt(candidates: [DeviceOption])
    /// Release devices from an AMI controller, chosen from the ones it currently
    /// controls. The inverse of `adopt`.
    case release(controlled: [DeviceOption])
    /// A parameter-less lifecycle command, by backend verb (e.g. `deactivate`).
    case simple(String)

    var id: String { backendCommand }

    /// Build a dispatchable command from a backend `available_commands` verb.
    /// `availableDirectives` is consulted only for `set_directive`, and the device
    /// option lists only for `adopt`/`release`, since those are device-/fleet-specific.
    init?(
        command: String,
        availableDirectives: [String] = [],
        adoptCandidates: [DeviceOption] = [],
        releaseCandidates: [DeviceOption] = []
    ) {
        switch command {
        case "travel":         self = .travel
        case "start_mining":   self = .mine
        case "retarget":       self = .retarget
        case "system_scan":    self = .scan
        case "scan":           self = .surveyScan
        case "stellar_census": self = .census
        case "enqueue_print":  self = .print
        case "stow":           self = .stow
        case "set_directive":  self = .setDirective(available: availableDirectives)
        case "adopt":          self = .adopt(candidates: adoptCandidates)
        case "release":        self = .release(controlled: releaseCandidates)
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
        case .surveyScan:    return "scan"
        case .census:        return "stellar_census"
        case .print:         return "enqueue_print"
        case .stow:          return "stow"
        case .setDirective:  return "set_directive"
        case .adopt:         return "adopt"
        case .release:       return "release"
        case let .simple(c): return c
        }
    }

    var kind: OperationKind {
        switch self {
        case .travel:        return .travel
        case .mine:          return .mine
        case .retarget:      return .retarget
        case .scan:          return .scan
        case .surveyScan:    return .surveyScan
        case .census:        return .census
        case .print:         return .print
        case .stow:          return .stow
        case .setDirective:  return .setDirective
        case .adopt:         return .adopt
        case .release:       return .release
        case let .simple(c): return .simple(c)
        }
    }

    var title: String {
        switch self {
        case .travel:        return "Travel"
        case .mine:          return "Mine"
        case .retarget:      return "Retarget"
        case .scan:          return "Scan"
        case .surveyScan:    return "Scan"
        case .census:        return "Census"
        case .print:         return "Print"
        case .stow:          return "Stow"
        case .setDirective:  return "Directive"
        case .adopt:         return "Adopt"
        case .release:       return "Release"
        case let .simple(c): return DevicePresentation.displayName(c)
        }
    }

    var systemImage: String {
        switch self {
        case .travel:        return "location.north.line"
        case .mine:          return "hammer"
        case .retarget:      return "scope"
        case .scan:          return "dot.radiowaves.up.forward"
        case .surveyScan:    return "viewfinder"
        case .census:        return "list.star"
        case .print:         return "printer"
        case .stow:          return "archivebox"
        case .setDirective:  return "brain.head.profile"
        case .adopt:         return "rectangle.stack.badge.plus"
        case .release:       return "rectangle.stack.badge.minus"
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
        /// A checkbox list — the user picks zero or more of `options` (used by
        /// `adopt`, which accepts multiple device codes at once).
        case multiSelect(label: String, options: [DeviceOption])
        /// A blueprint picker — the options are the unlocked catalog, supplied by
        /// the command grid from its `@FetchAll` (not carried in the enum).
        case blueprint(label: String)
        case none
    }

    var parameter: Parameter {
        switch self {
        case .travel:          return .text(label: "Destination", placeholder: "ATIANFU-1")
        case .print:           return .blueprint(label: "Blueprint")
        case .mine, .retarget: return .choice(label: "Resource", options: Self.miningResources)
        case let .setDirective(available): return .choice(label: "Directive", options: available)
        case let .adopt(candidates): return .multiSelect(label: "Devices", options: candidates)
        case let .release(controlled): return .multiSelect(label: "Devices", options: controlled)
        case .scan, .surveyScan, .census, .stow, .simple: return .none
        }
    }

    /// The `resource_type` values `start_mining` / `retarget` accept.
    static let miningResources = ["structural", "conductive", "silicates", "carbon", "volatiles", "rares"]

    /// The worker device type an AMI controller adopts, or nil if the type isn't a
    /// controller that scopes adoption to one kind. Mining/survey/transport
    /// controllers each shepherd their matching drone.
    static func controllableType(for controllerType: String) -> String? {
        switch controllerType {
        case "ami_mining_controller":    return "mining_drone"
        case "ami_survey_controller":    return "survey_drone"
        case "ami_transport_controller": return "transport_drone"
        default:                         return nil
        }
    }

    func params(_ value: String) -> CommandParams {
        switch self {
        case .travel:          return CommandParams(destination: value)
        case .print:           return CommandParams(deviceType: value)
        case .mine, .retarget: return CommandParams(resourceType: value)
        case .setDirective:    return CommandParams(directive: value)
        // adopt/release are multi-select — their params are built from the checkbox
        // selection in the command grid, not this single-value mapping.
        case .adopt, .release, .scan, .surveyScan, .census, .stow, .simple: return CommandParams()
        }
    }
}

/// One selectable device in the `adopt` checkbox list: its code (the id sent to
/// the server) plus a human subtitle for the row.
struct DeviceOption: Hashable, Identifiable {
    let id: String       // device_code
    let subtitle: String // e.g. "Idle · ATIANFU-1"
}
