//
//  DevicePresentation.swift
//  Replicould — Devices feature
//
//  View-side helpers that map backend strings to display: a device-type glyph
//  and human name, and which of a device's `available_commands` the inspector
//  can actually dispatch (travel / print today) and how they're parameterized.
//

import Foundation
import GameModels
import GameServices

enum DevicePresentation {
    /// "heaven_vessel" → "HEAVEN Vessel". Delegates to the shared GameModels
    /// helper so the special-casing rules live in one place.
    static func displayName(_ deviceType: String) -> String {
        BlueprintPresentation.displayName(deviceType)
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
    /// Attach devices to a carrier (surge plate). `candidates` are the devices
    /// sharing the carrier's location; `attachedCount`/`capacity` gate the UI —
    /// a single free slot shows a dropdown, several a capped multi-select, none a
    /// "full" notice.
    case attach(candidates: [DeviceOption], attachedCount: Int, capacity: Int)
    /// Detach devices from a carrier, chosen from the ones it currently carries.
    /// The inverse of `attach`.
    case detach(attached: [DeviceOption])
    /// Load a transport's cargo hold from the local stockpile (`collect_resources`).
    /// Opens the load sheet directly (its resource/quantity picker needs the
    /// location's live stockpile), so it carries no inline parameter.
    case loadCargo
    /// Unload a transport's cargo hold at its current location (`deposit_resources`),
    /// emptying it entirely. A confirm-only action.
    case unloadCargo
    /// Set a surge plate's carry mode (`configure`). `current` is the mode in
    /// force, seeding the picker so re-opening reflects reality.
    case configure(current: String?)
    /// Reassign this device to another of the account's replicants
    /// (`change_owner`), chosen from the other own replicants (threaded in at
    /// construction; empty — a one-replicant account — hides the command).
    case changeOwner(owners: [DeviceOption])
    /// Post a message to a BobNet channel from an FTL relay (`message`). The
    /// channel vocabulary is the locally-known channel list (threaded in at
    /// construction; empty — no channels synced yet — hides the command).
    case message(channels: [String])
    /// Repair a damaged device (`repair`), chosen from the fleet's
    /// under-capacity members (threaded in at construction; a fully healthy
    /// fleet hides the command).
    case repair(candidates: [DeviceOption])
    /// Spawn a new replicant from this matrix (`replicate`) into an empty
    /// replicant matrix at its location (threaded in at construction; no
    /// eligible matrix nearby hides the command). Dispatches through
    /// `ReplicantsClient` — the one command that answers 201 with a new
    /// replicant rather than a command result.
    case replicate(targets: [DeviceOption])
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
        releaseCandidates: [DeviceOption] = [],
        attachCandidates: [DeviceOption] = [],
        attachedCount: Int = 0,
        attachCapacity: Int = 0,
        detachCandidates: [DeviceOption] = [],
        currentMode: String? = nil,
        ownerCandidates: [DeviceOption] = [],
        channels: [String] = [],
        repairCandidates: [DeviceOption] = [],
        replicateTargets: [DeviceOption] = []
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
        case "attach":         self = .attach(candidates: attachCandidates, attachedCount: attachedCount, capacity: attachCapacity)
        case "detach":         self = .detach(attached: detachCandidates)
        case "collect_resources": self = .loadCargo
        case "deposit_resources": self = .unloadCargo
        case "configure":         self = .configure(current: currentMode)
        case "change_owner":      self = .changeOwner(owners: ownerCandidates)
        case "message":           self = .message(channels: channels)
        case "repair":            self = .repair(candidates: repairCandidates)
        case "replicate":         self = .replicate(targets: replicateTargets)
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
        case .attach:        return "attach"
        case .detach:        return "detach"
        case .loadCargo:     return "collect_resources"
        case .unloadCargo:   return "deposit_resources"
        case .configure:     return "configure"
        case .changeOwner:   return "change_owner"
        case .message:       return "message"
        case .repair:        return "repair"
        case .replicate:     return "replicate"
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
        case .attach:        return .attach
        case .detach:        return .detach
        case .loadCargo:     return .collectResources
        case .unloadCargo:   return .depositResources
        case .configure:     return .configure
        case .changeOwner:   return .changeOwner
        case .message:       return .message
        case .repair:        return .repair
        // never dispatched via CommandClient — replicate routes through ReplicantsClient
        case .replicate:     return OperationKind(rawValue: "replicate")
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
        case .attach:        return "Attach"
        case .detach:        return "Detach"
        case .loadCargo:     return "Load"
        case .unloadCargo:   return "Unload"
        case .configure:     return "Configure"
        case .changeOwner:   return "Change Owner"
        case .message:       return "Message"
        case .repair:        return "Repair"
        case .replicate:     return "Replicate"
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
        case .attach:        return "link"
        case .detach:        return "link.badge.minus"
        case .loadCargo:     return "tray.and.arrow.down"
        case .unloadCargo:   return "tray.and.arrow.up"
        case .configure:     return "gearshape"
        case .changeOwner:   return "person.2"
        case .message:       return "bubble.left"
        case .repair:        return "wrench.and.screwdriver"
        case .replicate:     return "person.badge.plus"
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
    ]

    /// Whether firing this command warrants a danger-styled confirm.
    var isDestructive: Bool {
        switch self {
        case let .simple(c): return c == "decommission"
        default:             return false
        }
    }

    /// What the inline panel collects before confirming.
    enum Parameter: Hashable {
        case text(label: String, placeholder: String)
        case choice(label: String, options: [String])
        /// A checkbox list — the user picks zero or more of `options` (adopt/release
        /// take any number; attach caps the selection at `limit` free slots, and a
        /// nil `limit` means uncapped).
        case multiSelect(label: String, options: [DeviceOption], limit: Int?)
        /// A single-select dropdown of devices — the user picks exactly one of
        /// `options` (attach into a single free slot, or detach a lone attachment).
        case deviceChoice(label: String, options: [DeviceOption])
        /// A blueprint picker — the options are the unlocked catalog, supplied by
        /// the command grid from its `@FetchAll` (not carried in the enum).
        case blueprint(label: String)
        /// A BobNet post: a channel dropdown plus the message body text field.
        case channelMessage(label: String, channels: [String])
        /// A replication: the target empty-matrix dropdown plus an optional
        /// name for the new replicant.
        case replicateTarget(label: String, options: [DeviceOption])
        /// An informational message with no input and a disabled confirm — e.g. a
        /// carrier that's at capacity, so attach can't proceed until a slot frees.
        case notice(String)
        case none
    }

    var parameter: Parameter {
        switch self {
        case .travel:          return .text(label: "Destination", placeholder: "ATIANFU-1")
        case .print:           return .blueprint(label: "Blueprint")
        case .mine, .retarget: return .choice(label: "Resource", options: Self.miningResources)
        case let .setDirective(available): return .choice(label: "Directive", options: available)
        case let .adopt(candidates): return .multiSelect(label: "Devices", options: candidates, limit: nil)
        case let .release(controlled): return .multiSelect(label: "Devices", options: controlled, limit: nil)
        case let .attach(candidates, attachedCount, capacity):
            let remaining = max(0, capacity - attachedCount)
            switch remaining {
            case 0:  return .notice("Carrier at capacity (\(attachedCount)/\(capacity)). Detach a device to free a slot.")
            case 1:  return .deviceChoice(label: "Device", options: candidates)
            default: return .multiSelect(label: "Devices", options: candidates, limit: remaining)
            }
        case let .detach(attached):
            return attached.count == 1
                ? .deviceChoice(label: "Device", options: attached)
                : .multiSelect(label: "Devices", options: attached, limit: nil)
        case .configure:
            return .choice(label: "Mode", options: SurgeMode.all)
        case let .changeOwner(owners):
            return .deviceChoice(label: "New Owner", options: owners)
        case let .message(channels):
            return .channelMessage(label: "Channel", channels: channels)
        case let .repair(candidates):
            return .deviceChoice(label: "Device", options: candidates)
        case let .replicate(targets):
            return .replicateTarget(label: "Target Matrix", options: targets)
        // loadCargo opens its own sheet (intercepted before an inline panel shows);
        // unloadCargo is a plain confirm. Neither collects an inline parameter.
        case .scan, .surveyScan, .census, .stow, .loadCargo, .unloadCargo, .simple: return .none
        }
    }

    /// The `resource_type` values `start_mining` / `retarget` accept.
    static let miningResources = ["structural", "conductive", "silicates", "carbon", "volatiles", "rares"]

    /// The `configure` carry modes a surge plate accepts.
    enum SurgeMode { static let all = ["taxi", "manual"] }

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
        case .configure:       return CommandParams(mode: value)
        case .changeOwner:     return CommandParams(target: value)
        case .repair:          return CommandParams(target: value)
        // adopt/release/attach build their params from the picker selection in the
        // command grid, not this single-value mapping; message builds its params
        // from two fields (channel + body) in the command grid as well; replicate
        // never dispatches through this path at all — it routes through
        // ReplicantsClient via `.replicateConfirmed`, not `params(for:)`.
        case .adopt, .release, .attach, .detach, .scan, .surveyScan, .census, .stow, .loadCargo, .unloadCargo, .message, .replicate, .simple: return CommandParams()
        }
    }
}

/// One selectable device in the `adopt` checkbox list: its code (the id sent to
/// the server) plus a human subtitle for the row.
struct DeviceOption: Hashable, Identifiable {
    let id: String       // device_code
    let subtitle: String // e.g. "Idle · ATIANFU-1"
}
