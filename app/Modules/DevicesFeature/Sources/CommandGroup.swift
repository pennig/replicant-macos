//
//  CommandGroup.swift
//  Replicould — Devices feature
//
//  The command grid's grouping taxonomy: every dispatchable backend verb is
//  assigned to one of eight named groups (Movement / Tasks / Production /
//  Control / Carrier & Cargo / Modular / Power / Special), rendered in a
//  stable order with only non-empty groups shown. Pure logic — no SwiftUI —
//  so the grid's arrangement is unit-testable (and statics on a View would
//  trap under `swift test`; see the project memory note).
//

/// One of the command grid's named sections, in declaration (= display) order.
enum CommandGroup: CaseIterable, Hashable {
    case movement, tasks, production, control, carrier, modular, power, special

    /// The section label shown above the group's buttons.
    var title: String {
        switch self {
        case .movement:   return "Movement"
        case .tasks:      return "Tasks"
        case .production: return "Production"
        case .control:    return "Control"
        case .carrier:    return "Carrier & Cargo"
        case .modular:    return "Modular"
        case .power:      return "Power"
        case .special:    return "Special"
        }
    }

    /// The group's backend verbs (`DeviceCommand.backendCommand`) in display
    /// order — the approved taxonomy from the device-command revamp design.
    var commandOrder: [String] {
        switch self {
        case .movement:   return ["travel", "recall", "deploy", "stow"]
        case .tasks:      return ["start_mining", "retarget", "scan", "search", "system_scan", "stellar_census"]
        case .production: return ["enqueue_print", "clear_queue"]
        case .control:    return ["set_directive", "clear_directive", "adopt", "release", "launch", "withdraw", "assemble"]
        case .carrier:    return ["attach", "detach", "configure", "collect_resources", "deposit_resources"]
        case .modular:    return ["compact", "unfurl"]
        case .power:      return ["activate", "deactivate"]
        case .special:    return ["decommission", "set_entry_point", "change_owner"]
        }
    }

    /// The group a backend verb belongs to. Unassigned verbs land in Special so
    /// a future command still renders somewhere rather than vanishing.
    static func group(for backendCommand: String) -> CommandGroup {
        allCases.first { $0.commandOrder.contains(backendCommand) } ?? .special
    }

    /// Fold a device's dispatchable commands into rendered sections: groups in
    /// declaration order, commands within a group in taxonomy order (verbs the
    /// taxonomy doesn't know keep their input order after the known ones),
    /// empty groups omitted.
    static func sections(for commands: [DeviceCommand]) -> [CommandSection] {
        allCases.compactMap { group in
            let members = commands.enumerated()
                .filter { Self.group(for: $0.element.backendCommand) == group }
                .sorted { lhs, rhs in
                    let l = group.commandOrder.firstIndex(of: lhs.element.backendCommand) ?? Int.max
                    let r = group.commandOrder.firstIndex(of: rhs.element.backendCommand) ?? Int.max
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                .map(\.element)
            return members.isEmpty ? nil : CommandSection(group: group, commands: members)
        }
    }
}

/// One rendered section of the command grid: a group and its commands, ready
/// for the view to lay out.
struct CommandSection: Equatable {
    let group: CommandGroup
    let commands: [DeviceCommand]
}
