//
//  CommandGrid.swift
//  Replicould — Devices feature
//
//  The device inspector's command surface: the device's dispatchable commands,
//  grouped into named sections (Movement / Tasks / …), and the inline confirm/parameter
//  panel each one reveals when selected (a text field, a directive picker with its own
//  configuration, a device checkbox list, a blueprint picker, or a plain confirmation).
//

import ComposableArchitecture
import GameModels
import GameServices
import SQLiteData
import SwiftUI
import UI
import UniverseModels
import Utils

struct CommandGrid: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, for building the `adopt` candidate list (worker devices of
    /// the type this controller shepherds).
    @FetchAll(Device.order { $0.deviceCode }) private var fleet
    /// The unlocked blueprint catalog, backing the `enqueue_print` dropdown.
    @FetchAll(Blueprint.order { $0.deviceType }) private var blueprints
    /// The local locations catalog, source of the `gather_salvage` site picker.
    /// One blob per explored system; the controller's system is decoded on demand.
    @FetchAll(SystemDetail.all) private var systemDetails
    @State private var pending: DeviceCommand?
    @State private var textValue: String = ""
    @State private var choiceValue: String = ""
    /// The selected blueprint's `device_type` for a pending `enqueue_print`.
    @State private var blueprintType: String = ""
    /// The checked device codes for a pending `adopt`.
    @State private var selectedCodes: Set<String> = []
    /// `survey_system` directive configuration, revealed when that directive is the
    /// pending `set_directive` selection.
    @State private var planetsScope: String = SurveyScope.all
    @State private var moonsScope: String = SurveyScope.none
    @State private var recall: Bool = true
    /// `gather_salvage` directive configuration: the chosen salvage-site
    /// designation, revealed when that directive is the pending selection.
    @State private var salvageLocation: String = ""
    /// AMI transport-controller directive configuration (`delivery` / `shuttle` /
    /// `ferry` / `consolidate`), revealed when one of those is the pending
    /// selection. `collect`/`deliver` are location designations; `requirement` is
    /// the per-resource target for a one-shot `delivery`; `priorityResources` is
    /// the ordered resource preference for the continuous directives.
    @State private var collectLocation: String = ""
    @State private var deliverLocation: String = ""
    @State private var requirement: [String: String] = [:]
    @State private var priorityResources: [String] = []

    /// The `all` / `none` scope values the survey config dropdowns offer.
    private enum SurveyScope { static let all = "all", none = "none" }

    /// The body the controller operates at — where its salvage drones are. A
    /// stowed controller carries no location of its own, so fall back to a
    /// controlled drone, then the stow-parent vessel, then any same-replicant
    /// device that reports a location.
    private var controllerBody: String? {
        if let loc = device.location, !loc.isEmpty { return loc }
        if let loc = device.controlledDevices.compactMap(\.location).first(where: { !$0.isEmpty }) { return loc }
        if let parent = device.stowedInDeviceCode,
           let loc = fleet.first(where: { $0.deviceCode == parent })?.location, !loc.isEmpty { return loc }
        return fleet.first { $0.replicantCode == device.replicantCode && ($0.location?.isEmpty == false) }?.location
    }

    /// The controller's star system designation (the leading segment of its
    /// operating body, e.g. "SHERATANON-7-4" → "SHERATANON").
    private var controllerSystem: String? {
        guard let body = controllerBody else { return nil }
        let system = String(body.split(separator: "-").first ?? "")
        return system.isEmpty ? nil : system
    }

    /// Salvage-bearing bodies in the controller's system, read from the local
    /// catalog. `gather_salvage` targets a body (working every site on it), so the
    /// picker offers bodies, not individual sites. Empty until the system is
    /// hydrated (see `.salvageSitesRequested`); depleted bodies drop out (stream
    /// depletion events keep this current — see LocationsClient.markSalvage*).
    private var salvageBodies: [SalvageBody] {
        guard
            let system = controllerSystem,
            let row = systemDetails.first(where: { $0.designation == system }),
            let starSystem = try? row.system()
        else { return [] }
        return starSystem.salvageBodies
    }

    /// The devices this controller can adopt: fleet members of the type it
    /// shepherds (mining drones for a mining controller, etc.) that it doesn't
    /// already control. Empty for a non-controller.
    private var adoptCandidates: [DeviceOption] {
        guard let type = DeviceCommand.controllableType(for: device.deviceType) else { return [] }
        let controlled = Set(device.controlledDeviceCodes)
        return fleet
            .filter { $0.deviceType == type && !controlled.contains($0.deviceCode) }
            .map { DeviceOption(id: $0.deviceCode, subtitle: adoptSubtitle($0)) }
    }

    /// "Idle · ATIANFU-1" — a candidate's status and where it is, for the row.
    private func adoptSubtitle(_ device: Device) -> String {
        let status = device.statusBase.capitalized
        if let place = device.locationName ?? device.location { return "\(status) · \(place)" }
        return status
    }

    /// The devices this controller already controls, for the release checkbox list.
    private var releaseCandidates: [DeviceOption] {
        device.controlledDevices.map {
            DeviceOption(id: $0.deviceCode, subtitle: controlledSubtitle($0))
        }
    }

    /// "Tracking · ATIANFU-BELT-1" — a controlled device's status and location.
    private func controlledSubtitle(_ device: Device.ControlledDevice) -> String {
        let status = (device.status?.isEmpty == false ? device.status! : device.deviceType).capitalized
        if let place = device.location, !place.isEmpty { return "\(status) · \(place)" }
        return status
    }

    /// The devices this carrier could attach: fleet members sharing its location
    /// that aren't already attached to something. Empty when the device can't
    /// attach or reports no location of its own. Capacity is *not* filtered here —
    /// a full carrier still lists candidates so the command surfaces its "full"
    /// notice rather than vanishing. The subtitle is the device's display type, so
    /// an entry reads "Mining Drone · 32658E70".
    private var attachCandidates: [DeviceOption] {
        guard device.features.contains("attach"), device.attachCapacity > 0 else { return [] }
        guard let location = device.location, !location.isEmpty else { return [] }
        let attached = Set(device.attachedDeviceCodes)
        return fleet
            .filter {
                $0.deviceCode != device.deviceCode
                    && $0.location == location
                    && $0.attachedToDeviceCode == nil
                    && !attached.contains($0.deviceCode)
            }
            .map { DeviceOption(id: $0.deviceCode, subtitle: DevicePresentation.displayName($0.deviceType)) }
    }

    /// The devices currently attached to this carrier, for the detach dropdown. The
    /// codes come from the carrier's `attached_devices` tail; the display type is
    /// looked up in the fleet so the entry reads "Autofactory · 43C9B54A". Empty
    /// when nothing is attached.
    private var detachCandidates: [DeviceOption] {
        device.attachedDeviceCodes.map { code in
            let type = fleet.first { $0.deviceCode == code }?.deviceType
            return DeviceOption(id: code, subtitle: type.map(DevicePresentation.displayName) ?? "Attached")
        }
    }

    /// The dispatchable subset of the device's available commands. `retarget` is
    /// gated on the device actually mining (the server rejects it otherwise);
    /// `set_directive` only surfaces when the device offers directives, and
    /// `adopt`/`release` only when there are devices to act on — empty pickers
    /// otherwise.
    private var commands: [DeviceCommand] {
        let adopt = adoptCandidates
        let release = releaseCandidates
        let attach = attachCandidates
        let detach = detachCandidates
        let attachedNow = device.attachedDeviceCodes.count
        let capacity = device.attachCapacity
        return device.availableCommands
            .compactMap {
                DeviceCommand(
                    command: $0,
                    availableDirectives: device.availableDirectives,
                    adoptCandidates: adopt,
                    releaseCandidates: release,
                    attachCandidates: attach,
                    attachedCount: attachedNow,
                    attachCapacity: capacity,
                    detachCandidates: detach
                )
            }
            .filter { command in
                switch command {
                case .retarget:               return device.status.lowercased().contains("mining")
                case let .setDirective(opts):  return !opts.isEmpty
                case let .adopt(candidates):   return !candidates.isEmpty
                case let .release(controlled): return !controlled.isEmpty
                case let .attach(candidates, _, _): return !candidates.isEmpty
                case let .detach(attached):    return !attached.isEmpty
                // Cargo commands only make sense while the transport is stationed at
                // a location: Load needs free hold space, Unload needs cargo aboard.
                case .loadCargo:   return device.cargoRemaining > 0 && device.location?.isEmpty == false
                case .unloadCargo: return !device.cargoItems.isEmpty && device.location?.isEmpty == false
                default:                      return true
                }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            RCSectionHeader("Commands")

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
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Space.s)], spacing: Space.s) {
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
            store.send(.cargoLoadRequested(
                deviceCode: device.deviceCode,
                location: device.location,
                locationName: device.locationName,
                capacityRemaining: device.cargoRemaining
            ))
            return
        }
        textValue = ""
        selectedCodes = []
        if case .print = command {
            // Seed the blueprint picker with the first catalog entry.
            blueprintType = blueprints.first?.deviceType ?? ""
        }
        switch command.parameter {
        case let .choice(_, options):
            // Seed the directive picker with the device's current directive when
            // it's a valid option, so re-opening reflects what's in force.
            if case .setDirective = command, let current = device.currentDirective, options.contains(current) {
                choiceValue = current
                seedDirectiveConfig()
            } else {
                choiceValue = options.first ?? ""
            }
            // Load any data the initially-selected directive's config needs.
            if case .setDirective = command { prepareDirective(choiceValue) }
        case let .deviceChoice(_, options):
            // Seed the dropdown with the first candidate device code.
            choiceValue = options.first?.id ?? ""
        default:
            choiceValue = ""
        }
        pending = command
    }

    /// Prepare the config controls for a newly-selected directive: seed defaults
    /// and, for `gather_salvage`, kick off a hydrate of the controller's system so
    /// the salvage-body dropdown fills from the local catalog.
    private func prepareDirective(_ directive: String) {
        guard directive == "gather_salvage" else { return }
        if salvageLocation.isEmpty { salvageLocation = salvageBodies.first?.designation ?? "" }
        if let system = controllerSystem, let body = controllerBody {
            store.send(.salvageSitesRequested(system: system, body: body))
        }
    }

    /// Seed the config controls from the directive currently in force, so
    /// re-opening the picker mirrors what's running. Falls back to the documented
    /// defaults (survey planets: all, moons: none, recall: on) when no config is
    /// present.
    private func seedDirectiveConfig() {
        planetsScope = SurveyScope.all
        moonsScope = SurveyScope.none
        recall = true
        salvageLocation = ""
        collectLocation = ""
        deliverLocation = ""
        requirement = [:]
        priorityResources = []
        guard let config = device.currentDirectiveConfig else { return }
        switch device.currentDirective {
        case "survey_system":
            planetsScope = config["planets"]?.stringValue ?? planetsScope
            moonsScope = config["moons"]?.stringValue ?? moonsScope
            recall = config["recall"]?.boolValue ?? recall
        case "gather_salvage":
            salvageLocation = config["location"]?.stringValue ?? ""
            recall = config["recall"]?.boolValue ?? recall
        case "delivery":
            // The backend nests a one-shot delivery's endpoints under `route`.
            collectLocation = config["route"]?["collect"]?.stringValue ?? ""
            deliverLocation = config["route"]?["deliver"]?.stringValue ?? ""
            if case let .object(target)? = config["requirement"] {
                requirement = target.reduce(into: [:]) { acc, pair in
                    if let amount = pair.value.numberValue { acc[pair.key] = Self.amountString(amount) }
                }
            }
        case "shuttle", "ferry":
            collectLocation = config["collect"]?.stringValue ?? ""
            deliverLocation = config["deliver"]?.stringValue ?? ""
            priorityResources = config["priority"]?.arrayValue?.compactMap(\.stringValue) ?? []
        case "consolidate":
            deliverLocation = config["deliver"]?.stringValue ?? ""
            priorityResources = config["priority"]?.arrayValue?.compactMap(\.stringValue) ?? []
        default:
            break
        }
    }

    /// Render a requirement amount without a trailing `.0` so a whole number
    /// round-trips as "50" rather than "50.0".
    private static func amountString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    @ViewBuilder
    private func parameterPanel(_ command: DeviceCommand) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            switch command.parameter {
            case let .text(label, placeholder):
                RCField(label, text: $textValue, placeholder: placeholder, mono: true)
            case let .choice(label, options):
                VStack(alignment: .leading, spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(label.uppercased())
                            .font(.rcSectionLabel)
                            .foregroundStyle(.rcTextTertiary)
                        RCValueSelect(label, options: options, selection: $choiceValue)
                    }
                    // A directive with its own configuration reveals it inline once
                    // selected (survey_system and gather_salvage; other directives
                    // take none).
                    if case .setDirective = command {
                        directiveConfiguration(choiceValue)
                            .onChange(of: choiceValue) { _, newValue in
                                prepareDirective(newValue)
                            }
                    }
                }
            case let .multiSelect(label, options, limit):
                deviceCheckboxList(label, options: options, limit: limit)
            case let .deviceChoice(label, options):
                deviceChoicePicker(label, options: options)
            case let .blueprint(label):
                blueprintPicker(label)
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
        case .blueprint:    return blueprintType
        case .multiSelect:  return ""
        case .notice:       return ""
        case .none:         return ""
        }
    }

    /// The dispatch params for a command. `set_directive` attaches the selected
    /// directive's configuration and `adopt` the checked device codes; every other
    /// command uses the plain single-value mapping.
    private func params(for command: DeviceCommand) -> CommandParams {
        switch command {
        case .setDirective:
            return CommandParams(directive: choiceValue, configuration: directiveConfig(for: choiceValue))
        case .adopt, .release:
            return CommandParams(devices: Array(selectedCodes))
        case .attach, .detach:
            // Either a single-slot dropdown (one chosen code) or a multi-select
            // (the checked codes), depending on how many slots / attachments there are.
            if case .deviceChoice = command.parameter {
                return CommandParams(devices: [choiceValue])
            }
            return CommandParams(devices: Array(selectedCodes))
        default:
            return command.params(confirmValue(for: command))
        }
    }

    /// The configuration object for a directive, or nil for directives that take
    /// none (belt_search and the rest). `survey_system` and `gather_salvage` are
    /// configurable today.
    private func directiveConfig(for directive: String) -> [String: JSONValue]? {
        switch directive {
        case "survey_system":
            return [
                "planets": .string(planetsScope),
                "moons": .string(moonsScope),
                "recall": .bool(recall),
            ]
        case "gather_salvage":
            return [
                "location": .string(salvageLocation),
                "recall": .bool(recall),
            ]
        case "delivery":
            // A one-shot transfer: endpoints nest under `route`, and the
            // per-resource `requirement` defines when the run is complete.
            var config: [String: JSONValue] = [
                "route": .object([
                    "collect": .string(collectLocation),
                    "deliver": .string(deliverLocation),
                ]),
            ]
            let target = requirementPayload
            if !target.isEmpty { config["requirement"] = .object(target) }
            return config
        case "shuttle", "ferry":
            // Continuous in-system (shuttle) / interstellar (ferry) transport:
            // flat endpoints with an optional ordered resource `priority`.
            var config: [String: JSONValue] = [
                "collect": .string(collectLocation),
                "deliver": .string(deliverLocation),
            ]
            if !priorityResources.isEmpty {
                config["priority"] = .array(priorityResources.map(JSONValue.string))
            }
            return config
        case "consolidate":
            // Gather dispersed system resources to a single destination.
            var config: [String: JSONValue] = ["deliver": .string(deliverLocation)]
            if !priorityResources.isEmpty {
                config["priority"] = .array(priorityResources.map(JSONValue.string))
            }
            return config
        default:
            return nil
        }
    }

    /// The `delivery` requirement object: the resources with a positive amount,
    /// keyed by resource type. Blank or non-positive rows are dropped.
    private var requirementPayload: [String: JSONValue] {
        requirement.reduce(into: [:]) { acc, pair in
            let trimmed = pair.value.trimmingCharacters(in: .whitespaces)
            if let amount = Double(trimmed), amount > 0 { acc[pair.key] = .number(amount) }
        }
    }

    /// Inline configuration controls for a configurable directive. Empty for
    /// directives that carry no configuration.
    @ViewBuilder
    private func directiveConfiguration(_ directive: String) -> some View {
        switch directive {
        case "survey_system":
            VStack(alignment: .leading, spacing: Space.s) {
                configField("Planets", selection: $planetsScope)
                configField("Moons", selection: $moonsScope)
                Toggle(isOn: $recall) {
                    Text("Recall when complete")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextSecondary)
                }
                .toggleStyle(.switch)
                .tint(.rcAccent)
            }
            .padding(.top, Space.xs)
        case "gather_salvage":
            salvageConfiguration
        case "delivery":
            deliveryConfiguration
        case "shuttle":
            transportRouteConfiguration(interstellar: false)
        case "ferry":
            transportRouteConfiguration(interstellar: true)
        case "consolidate":
            consolidateConfiguration
        default:
            EmptyView()
        }
    }

    /// The `delivery` config: a one-shot collect → deliver route plus the
    /// per-resource target that defines when the run is complete. The backend
    /// rejects the directive without a requirement, so confirm stays disabled
    /// until both endpoints and at least one amount are set.
    @ViewBuilder
    private var deliveryConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCField("Collect From", text: $collectLocation, placeholder: "ATIANFU-BELT-1", mono: true)
            RCField("Deliver To", text: $deliverLocation, placeholder: "ALPHERATOZ-8-L4", mono: true)
            requirementEditor
        }
        .padding(.top, Space.xs)
    }

    /// The `shuttle` (in-system) / `ferry` (interstellar) config: a continuous
    /// collect → deliver route with an optional ordered resource priority.
    @ViewBuilder
    private func transportRouteConfiguration(interstellar: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCField(
                "Collect From",
                text: $collectLocation,
                placeholder: interstellar ? "TARAZEDAR-BELT-1" : "ATIANFU-BELT-1",
                hint: interstellar ? "source system" : nil,
                mono: true
            )
            RCField(
                "Deliver To",
                text: $deliverLocation,
                placeholder: "ALPHERATOZ-8-L4",
                hint: interstellar ? "destination system" : nil,
                mono: true
            )
            priorityEditor
        }
        .padding(.top, Space.xs)
    }

    /// The `consolidate` config: a single destination that dispersed system
    /// resources are gathered to, with an optional ordered resource priority.
    @ViewBuilder
    private var consolidateConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCField("Deliver To", text: $deliverLocation, placeholder: "ALPHERATOZ-8-L4", mono: true)
            priorityEditor
        }
        .padding(.top, Space.xs)
    }

    /// The `delivery` requirement editor: one numeric field per resource type.
    /// Only resources with a positive amount are sent; together they define the
    /// quota that completes the one-shot run.
    @ViewBuilder
    private var requirementEditor: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Requirement")
            Text("Amounts to deliver before the run completes.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
            VStack(spacing: 0) {
                ForEach(Array(DeviceCommand.miningResources.enumerated()), id: \.element) { index, resource in
                    if index > 0 { Divider().overlay(Color.rcSeparator) }
                    requirementRow(resource)
                }
            }
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

    /// One requirement row — a resource label and a trailing numeric field.
    private func requirementRow(_ resource: String) -> some View {
        HStack(spacing: Space.s) {
            Text(resource.capitalized)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
            Spacer(minLength: 0)
            TextField("0", text: requirementBinding(resource))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.rcMonoSmall)
                .frame(width: 56)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    /// A string binding into the `requirement` map for a resource, so an empty
    /// field clears the entry rather than leaving a stale amount.
    private func requirementBinding(_ resource: String) -> Binding<String> {
        Binding(
            get: { requirement[resource] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { requirement[resource] = nil }
                else { requirement[resource] = trimmed }
            }
        )
    }

    /// The ordered resource-priority editor for the continuous transport
    /// directives. Tapping a resource appends it (its badge shows the rank);
    /// tapping again removes it and the remaining ranks close up. Empty means
    /// "balance everything".
    @ViewBuilder
    private var priorityEditor: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Priority")
            Text("Tap to rank resources in order. Leave empty to balance all.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: Space.xs)],
                spacing: Space.xs
            ) {
                ForEach(DeviceCommand.miningResources, id: \.self) { resource in
                    priorityChip(resource)
                }
            }
        }
    }

    /// A single priority chip: accent-filled with its rank number when selected,
    /// a bordered surface otherwise.
    private func priorityChip(_ resource: String) -> some View {
        let rank = priorityResources.firstIndex(of: resource)
        let selected = rank != nil
        return Button {
            togglePriority(resource)
        } label: {
            HStack(spacing: Space.xs) {
                if let rank {
                    Text("\(rank + 1)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcAccentOnColor)
                }
                Text(resource.capitalized)
                    .font(.rcCaption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .rcAccentOnColor : .rcTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xs)
            .padding(.horizontal, Space.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? Color.rcAccent : Color.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(selected ? Color.clear : Color.rcSeparator, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Toggle a resource in the ordered priority list, appending it at the end
    /// (lowest current rank) or removing it.
    private func togglePriority(_ resource: String) {
        if let index = priorityResources.firstIndex(of: resource) {
            priorityResources.remove(at: index)
        } else {
            priorityResources.append(resource)
        }
    }

    /// The `gather_salvage` config: a required salvage-body picker (sourced from
    /// the controller's system in the local catalog) plus the recall toggle. The
    /// directive targets a body — its drones work every salvage site there — so
    /// the picker offers bodies. The backend rejects the directive without a
    /// `location`, so confirm stays disabled until a body is chosen.
    @ViewBuilder
    private var salvageConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                RCSectionHeader("Salvage Location")
                if salvageBodies.isEmpty {
                    Text("No known salvage in this system yet. Scan its bodies in Locations to reveal them.")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                } else {
                    RCValueSelect(
                        "Salvage Location",
                        options: salvageBodies.map {
                            (label: salvageBodyLabel($0), value: $0.designation)
                        },
                        selection: $salvageLocation
                    )
                }
            }
            Toggle(isOn: $recall) {
                Text("Recall when complete")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
            }
            .toggleStyle(.switch)
            .tint(.rcAccent)
        }
        .padding(.top, Space.xs)
        // Auto-select the first body once the catalog hydrates, unless one is
        // already chosen (kept selection or a seeded running directive).
        .onChange(of: salvageBodies.map(\.id)) { _, _ in
            if salvageLocation.isEmpty { salvageLocation = salvageBodies.first?.designation ?? "" }
        }
    }

    /// A salvage body's dropdown label — its name/designation, annotated with the
    /// site count when it holds more than one (the drones work them all).
    private func salvageBodyLabel(_ body: SalvageBody) -> String {
        body.siteCount > 1 ? "\(body.displayName) · \(body.siteCount) sites" : body.displayName
    }

    /// A labeled all/none scope dropdown for a survey config field.
    private func configField(_ label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label.uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            RCValueSelect(label, options: [SurveyScope.all, SurveyScope.none], selection: selection)
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
        case .choice:
            // Some directives carry required config the backend rejects without.
            if case .setDirective = command {
                switch choiceValue {
                case "gather_salvage":
                    return !salvageLocation.isEmpty
                case "delivery":
                    // Needs both endpoints and at least one resource target.
                    return !collectLocation.isEmpty && !deliverLocation.isEmpty && !requirementPayload.isEmpty
                case "shuttle", "ferry":
                    return !collectLocation.isEmpty && !deliverLocation.isEmpty
                case "consolidate":
                    return !deliverLocation.isEmpty
                default:
                    break
                }
            }
            return !choiceValue.isEmpty
        case .deviceChoice: return !choiceValue.isEmpty
        case .blueprint:   return !blueprintType.isEmpty
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
