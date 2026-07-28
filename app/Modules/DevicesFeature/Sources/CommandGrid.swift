//
//  CommandGrid.swift
//  Replicould — Devices feature
//
//  The device inspector's command surface: the device's dispatchable commands,
//  grouped into named sections (Movement / Tasks / …), and the inline confirm/parameter
//  panel each one reveals when selected (a text field, a resource picker, a device
//  checkbox list, a blueprint picker, or a plain confirmation); heavier commands (travel /
//  print / cargo / directive) confirm in their own sheets.
//

import ComposableArchitecture
import GameModels
import GameServices
import SQLiteData
import SwiftUI
import UI

struct CommandGrid: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, for building the `adopt` candidate list (worker devices of
    /// the type this controller shepherds).
    @FetchAll(Device.order { $0.deviceCode }) private var fleet
    /// The unlocked blueprint catalog, backing the `enqueue_print` dropdown.
    @FetchAll(Blueprint.order { $0.deviceType }) private var blueprints
    /// The account's own replicants, backing the `change_owner` target picker.
    @FetchAll(Replicant.all) private var replicants
    /// The locally-known BobNet channels, backing the `message` channel picker.
    @FetchAll(BobnetChannel.order { $0.name }) private var channels
    @State private var pending: DeviceCommand?
    @State private var textValue: String = ""
    @State private var choiceValue: String = ""
    /// The selected blueprint's `device_type` for a pending `enqueue_print`.
    @State private var blueprintType: String = ""
    /// The checked device codes for a pending `adopt`.
    @State private var selectedCodes: Set<String> = []
    /// Whether a pending `stow` names an explicit target vessel (the opt-in
    /// checkbox). Off means "let the server stow it in the owner's vessel".
    @State private var targetEnabled: Bool = false

    /// The candidate lists the inline panels pick from. Each delegates to
    /// `CommandAvailability` — the rules themselves are pure and tested there
    /// (the V3.6 T6 extraction); these are only the view's bindings from the
    /// observed fleet/roster tables into those rules.
    private var adoptCandidates: [DeviceOption] {
        CommandAvailability.adoptCandidates(device: device, fleet: fleet)
    }

    private var releaseCandidates: [DeviceOption] {
        CommandAvailability.releaseCandidates(device: device)
    }

    private var attachCandidates: [DeviceOption] {
        CommandAvailability.attachCandidates(device: device, fleet: fleet)
    }

    private var detachCandidates: [DeviceOption] {
        CommandAvailability.detachCandidates(device: device, fleet: fleet)
    }

    private var stowTargets: [DeviceOption] {
        CommandAvailability.stowTargets(device: device, fleet: fleet)
    }

    private var ownerCandidates: [DeviceOption] {
        CommandAvailability.ownerCandidates(device: device, replicants: replicants)
    }

    private var repairCandidates: [DeviceOption] {
        CommandAvailability.repairCandidates(device: device, fleet: fleet)
    }

    private var replicateTargets: [DeviceOption] {
        CommandAvailability.replicateTargets(device: device, fleet: fleet)
    }

    /// The dispatchable subset of the device's available commands, including every
    /// availability gate. Pure policy — see `CommandAvailability.commands`.
    private var commands: [DeviceCommand] {
        CommandAvailability.commands(
            device: device,
            fleet: fleet,
            replicants: replicants,
            channels: channels.map(\.name)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Commands")
                .font(.rcBodyEmph)
                .foregroundStyle(.rcTextSecondary)

            if commands.isEmpty {
                Text("No dispatchable commands for this device yet.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            } else {
                // A device out of its controller's range can't be issued commands —
                // disable the whole grid (and suppress any confirm panel) until it's
                // back in range. The status badge already conveys "out of range", so
                // this just gates interaction rather than restating it loudly.
                let outOfRange = device.isOutOfControlRange
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(CommandGroup.sections(for: commands), id: \.group) { section in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(section.group.title.uppercased())
                                .font(.rcSectionLabel)
                                .foregroundStyle(.rcTextTertiary)
                            // A flow layout rather than a fixed adaptive grid: every
                            // button gets a uniform width that flexes between max(120,
                            // 20% of the panel) and a 200 cap, but any whose label needs
                            // more room grows past the cap, instead of clipping the way a
                            // 120-wide grid cell would.
                            FlowLayout(spacing: Space.s, minItemWidth: 120, minItemWidthFraction: 0.2, maxItemWidth: 200) {
                                ForEach(section.commands) { command in
                                    Button {
                                        select(command)
                                    } label: {
                                        Label(command.title, systemImage: command.systemImage)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(RCButtonStyle(pending == command ? .primary : .secondary))
                                }
                            }
                        }
                    }
                }
                .disabled(outOfRange)

                if let pending, !outOfRange {
                    parameterPanel(pending)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Toggle a command's confirm panel, seeding any default parameter value.
    private func select(_ command: DeviceCommand) {
        if pending == command { pending = nil; return }
        // Load Cargo skips the inline panel — its resource/quantity picker needs the
        // location's live stockpile, so it opens a sheet straight from the grid.
        if case .loadCargo = command {
            pending = nil
            store.send(.cargoLoadTapped(
                deviceCode: device.deviceCode,
                location: device.location,
                locationName: device.locationName,
                capacityRemaining: device.cargoRemaining
            ))
            return
        }
        // Directive skips the inline panel too — its editor is a full form fed
        // by live catalog data, so it opens the composer sheet from the grid.
        if case .setDirective = command {
            pending = nil
            store.send(.directiveComposeTapped)
            return
        }
        textValue = ""
        selectedCodes = []
        targetEnabled = false
        if case .print = command {
            // Seed the blueprint picker with the first catalog entry.
            blueprintType = blueprints.first?.deviceType ?? ""
        }
        switch command.parameter {
        case let .choice(_, options):
            // Seed the dropdown with the first option (mine/retarget resources) —
            // except Configure, which seeds from the mode currently in force.
            if case let .configure(current) = command, let current, options.contains(current) {
                choiceValue = current
            } else {
                choiceValue = options.first ?? ""
            }
        case let .deviceChoice(_, options):
            // Seed the dropdown with the first candidate device code.
            choiceValue = options.first?.id ?? ""
        case let .optionalDeviceChoice(_, options, _):
            // Seed the (initially hidden) target dropdown with the first vessel.
            choiceValue = options.first?.id ?? ""
        case let .channelMessage(_, channels):
            // Seed the channel dropdown; the body text starts empty.
            choiceValue = channels.first ?? ""
        case let .replicateTarget(_, options):
            choiceValue = options.first?.id ?? ""
        default:
            choiceValue = ""
        }
        pending = command
    }

    @ViewBuilder
    private func parameterPanel(_ command: DeviceCommand) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            switch command.parameter {
            case let .text(label, placeholder):
                RCField(label, text: $textValue, placeholder: placeholder, mono: true)
            case let .choice(label, options):
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(label.uppercased())
                        .font(.rcSectionLabel)
                        .foregroundStyle(.rcTextTertiary)
                    RCValueSelect(label, options: options, selection: $choiceValue)
                }
            case let .multiSelect(label, options, limit):
                deviceCheckboxList(label, options: options, limit: limit)
            case let .deviceChoice(label, options):
                deviceChoicePicker(label, options: options)
            case let .optionalDeviceChoice(label, options, toggleLabel):
                VStack(alignment: .leading, spacing: Space.s) {
                    Toggle(toggleLabel, isOn: $targetEnabled)
                        .toggleStyle(.checkbox)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextSecondary)
                    if targetEnabled {
                        deviceChoicePicker(label, options: options)
                    } else {
                        Text("Stows in the replicant owner's vessel.")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
            case let .blueprint(label):
                blueprintPicker(label)
            case let .channelMessage(label, channels):
                VStack(alignment: .leading, spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(label.uppercased())
                            .font(.rcSectionLabel)
                            .foregroundStyle(.rcTextTertiary)
                        RCValueSelect(label, options: channels, selection: $choiceValue)
                    }
                    RCField("Message", text: $textValue, placeholder: "On our way with the volatiles.")
                }
            case let .replicateTarget(label, options):
                VStack(alignment: .leading, spacing: Space.s) {
                    deviceChoicePicker(label, options: options)
                    RCField("Name", text: $textValue, placeholder: "Optional — server names it otherwise")
                }
            case let .notice(message):
                Text(message)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                Text(confirmPrompt(for: command))
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { pending = nil }
                    .buttonStyle(RCButtonStyle(.secondary))
                // Travel takes an extra beat: preview the dry-run itinerary in a
                // sheet and let the user confirm there. Every other command
                // dispatches straight from here.
                Button(confirmTitle(for: command)) {
                    // Thin sender: collapse the panel and hand the intent to the
                    // reducer. The reducer ends field editing and yields a runloop
                    // tick before presenting the sheet (a sheet presented while the
                    // destination field's text-completion popover is up crashes
                    // AppKit's sheet presentation) — that logic lives behind
                    // dependencies so it's testable. See `.travelConfirmed`.
                    pending = nil
                    if command == .travel {
                        store.send(.travelConfirmed(
                            deviceCode: device.deviceCode,
                            destination: confirmValue(for: command)
                        ))
                    } else if command == .print {
                        store.send(.printConfirmed(
                            deviceCode: device.deviceCode,
                            deviceType: blueprintType,
                            location: device.location,
                            locationName: device.locationName,
                            required: requiredLines(for: blueprintType)
                        ))
                    } else if case .replicate = command {
                        let name = textValue.trimmingCharacters(in: .whitespaces)
                        store.send(.replicateConfirmed(
                            deviceCode: device.deviceCode,
                            target: choiceValue,
                            name: name.isEmpty ? nil : name
                        ))
                    } else {
                        // No sheet — dispatch straight through.
                        store.send(.commandConfirmed(
                            kind: command.kind,
                            deviceCode: device.deviceCode,
                            params: params(for: command)
                        ))
                    }
                }
                .buttonStyle(RCButtonStyle(command.isDestructive ? .destructiveProminent : .primary))
                .disabled(!isConfirmable(command))
            }
        }
        .padding(Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcAccentBorder, lineWidth: Hairline.thin)
                )
        )
    }

    /// The prompt shown in a confirm-only (`.none`) panel. Unload spells out that it
    /// empties the whole hold; everything else is a plain "Run X on CODE?".
    private func confirmPrompt(for command: DeviceCommand) -> String {
        if case .unloadCargo = command {
            let place = device.locationName ?? device.location ?? "its current location"
            return "Unload the entire cargo hold at \(place)?"
        }
        return "Run \(command.title) on \(device.deviceCode)?"
    }

    /// The confirm button's title. Travel reviews a route first; adopt shows how
    /// many devices are checked.
    private func confirmTitle(for command: DeviceCommand) -> String {
        if command == .travel { return "Review Route…" }
        if command == .print { return "Review Cost…" }
        if case .unloadCargo = command { return "Unload All" }
        if case .replicate = command { return "Replicate" }
        if !selectedCodes.isEmpty {
            if case .adopt = command { return "Adopt \(selectedCodes.count)" }
            if case .release = command { return "Release \(selectedCodes.count)" }
            if case .attach = command { return "Attach \(selectedCodes.count)" }
            if case .detach = command { return "Detach \(selectedCodes.count)" }
        }
        return command.title
    }

    /// The value passed to `params(_:)` for the pending command's parameter kind.
    private func confirmValue(for command: DeviceCommand) -> String {
        switch command.parameter {
        case .text:         return textValue
        case .choice:       return choiceValue
        case .deviceChoice: return choiceValue
        case .optionalDeviceChoice: return targetEnabled ? choiceValue : ""
        case .blueprint:    return blueprintType
        case .channelMessage: return choiceValue
        case .replicateTarget: return choiceValue
        case .multiSelect:  return ""
        case .notice:       return ""
        case .none:         return ""
        }
    }

    /// The dispatch params for a command. `adopt` uses the checked device codes;
    /// every other command uses the plain single-value mapping.
    private func params(for command: DeviceCommand) -> CommandParams {
        switch command {
        case .adopt, .release:
            return CommandParams(devices: Array(selectedCodes))
        case .attach, .detach:
            // Either a single-slot dropdown (one chosen code) or a multi-select
            // (the checked codes), depending on how many slots / attachments there are.
            if case .deviceChoice = command.parameter {
                return CommandParams(devices: [choiceValue])
            }
            return CommandParams(devices: Array(selectedCodes))
        case .stow:
            // The target vessel is optional: only send it when the checkbox is on.
            return CommandParams(target: targetEnabled ? choiceValue : nil)
        case .message:
            return CommandParams(channel: choiceValue, text: textValue.trimmingCharacters(in: .whitespaces))
        default:
            return command.params(confirmValue(for: command))
        }
    }

    /// A multi-select checkbox list: one selectable row per eligible device, capped
    /// in height so a large fleet scrolls rather than pushing the confirm out of
    /// view. `limit` (attach's free slots) caps how many can be checked; a header
    /// counter shows the running total and a Select-All/Clear toggle fills or
    /// empties the selection (respecting `limit`).
    private func deviceCheckboxList(_ label: String, options: [DeviceOption], limit: Int?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text(label.uppercased())
                    .font(.rcSectionLabel)
                    .foregroundStyle(.rcTextTertiary)
                if let limit {
                    Text("\(selectedCodes.count)/\(limit)")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                } else if !selectedCodes.isEmpty {
                    Text("\(selectedCodes.count)")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
                Spacer(minLength: 0)
                Button(selectAllFilled(options, limit: limit) ? "Clear" : "Select All") {
                    toggleSelectAll(options, limit: limit)
                }
                .buttonStyle(.plain)
                .font(.rcCaption)
                .foregroundStyle(.rcAccent)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        checkboxRow(option, limit: limit)
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 1)
                    )
            )
        }
    }

    /// The codes Select-All would check: every option, or the first `limit` when
    /// capped. "Filled" means all of those are already selected.
    private func selectAllTargets(_ options: [DeviceOption], limit: Int?) -> [String] {
        let ids = options.map(\.id)
        return limit.map { Array(ids.prefix($0)) } ?? ids
    }

    private func selectAllFilled(_ options: [DeviceOption], limit: Int?) -> Bool {
        let target = selectAllTargets(options, limit: limit)
        return !target.isEmpty && target.allSatisfy(selectedCodes.contains)
    }

    /// Toggle between fully selected (up to `limit`) and cleared.
    private func toggleSelectAll(_ options: [DeviceOption], limit: Int?) {
        if selectAllFilled(options, limit: limit) {
            selectedCodes.subtract(options.map(\.id))
        } else {
            selectedCodes = Set(selectAllTargets(options, limit: limit))
        }
    }

    /// The `attach` device dropdown: one entry per same-location candidate, labeled
    /// "Type · CODE" and valued by device code. A single-select carrier (surge
    /// plate) holds one device at a time, so a dropdown fits better than a checkbox
    /// list.
    private func deviceChoicePicker(_ label: String, options: [DeviceOption]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label.uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            RCValueSelect(
                label,
                options: options.map { (label: "\($0.subtitle) · \($0.id)", value: $0.id) },
                selection: $choiceValue
            )
        }
    }

    /// One device row — a checkbox glyph, the device code, and a status subtitle —
    /// toggling the code in/out of the pending selection. When `limit` is reached,
    /// unchecked rows dim and stop responding so the selection can't exceed the
    /// carrier's free slots.
    private func checkboxRow(_ option: DeviceOption, limit: Int?) -> some View {
        let selected = selectedCodes.contains(option.id)
        let atLimit = limit.map { selectedCodes.count >= $0 } ?? false
        let blocked = !selected && atLimit
        return Button {
            if selected { selectedCodes.remove(option.id) }
            else if !blocked { selectedCodes.insert(option.id) }
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(selected ? Color.rcAccent : .rcTextTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.id)
                        .font(.rcMono)
                        .foregroundStyle(.rcTextPrimary)
                    Text(option.subtitle)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .opacity(blocked ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
    }

    /// Whether the confirm button is enabled — text must be non-empty and a
    /// multi-select needs at least one checked device; choice and confirm-only
    /// commands are always ready.
    private func isConfirmable(_ command: DeviceCommand) -> Bool {
        switch command.parameter {
        case .text:        return !textValue.trimmingCharacters(in: .whitespaces).isEmpty
        case .choice:      return !choiceValue.isEmpty
        case .deviceChoice: return !choiceValue.isEmpty
        // Optional target: always confirmable; if the checkbox is on it needs a pick.
        case .optionalDeviceChoice: return !targetEnabled || !choiceValue.isEmpty
        case .blueprint:   return !blueprintType.isEmpty
        case .channelMessage:
            return !choiceValue.isEmpty && !textValue.trimmingCharacters(in: .whitespaces).isEmpty
        case .replicateTarget: return !choiceValue.isEmpty
        case .multiSelect: return !selectedCodes.isEmpty
        case .notice:      return false
        case .none:        return true
        }
    }

    // MARK: Blueprint picker

    /// The `enqueue_print` blueprint dropdown: every unlocked catalog entry,
    /// labeled by display name and valued by `device_type`.
    private func blueprintPicker(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label.uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            if blueprints.isEmpty {
                Text("No blueprints unlocked yet.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            } else {
                RCValueSelect(
                    label,
                    options: blueprints.map {
                        (label: DevicePresentation.displayName($0.deviceType), value: $0.deviceType)
                    },
                    selection: $blueprintType
                )
            }
        }
    }

    /// The resource cost of a blueprint as confirmation lines (stock filled in
    /// later from the location's live inventory). Empty when the blueprint is
    /// unknown or lists no cost.
    private func requiredLines(for deviceType: String) -> [PrintResourceLine] {
        guard let blueprint = blueprints.first(where: { $0.deviceType == deviceType }) else { return [] }
        return blueprint.resources.lineItems.map { item in
            PrintResourceLine(
                resource: item.label.lowercased(),
                label: item.label,
                required: Double(item.amount)
            )
        }
    }
}
