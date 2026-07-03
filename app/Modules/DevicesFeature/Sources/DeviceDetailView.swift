//
//  DeviceDetailView.swift
//  Replicould — Devices feature
//
//  The device inspector for the split view's detail column: header, an
//  operational-capacity ring, an active-task card (live progress + ETA from the
//  device's open `Operation`, interpolated with zero network by
//  `OperationProgressView`), a details readout, and a command grid whose
//  parameterized commands (travel / print) reveal an inline confirm panel.
//  Everything observes SQLite, so a relay update or a dispatched op re-renders
//  the pane automatically.
//

import BlueprintsFeature
import ComposableArchitecture
import DependencyClients
import GameModels
import IssueReporting
import SQLiteData
import SwiftUI
import UI
import Utils

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

public struct DeviceDetailView: View {
    let store: StoreOf<DevicesFeature>
    @FetchAll(Operation.order { $0.startedAt.desc() }) private var operations

    public init(store: StoreOf<DevicesFeature>) {
        self.store = store
    }

    /// The device's single open operation, if any.
    private var openOperation: Operation? {
        guard let code = store.selectedDeviceCode else { return nil }
        return operations.first {
            $0.entityCode == code && $0.status.isOpen
        }
    }

    public var body: some View {
        Group {
            if let device = store.selectedDevice {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        header(device)
                        readouts(device)
                        details(device)
                        CommandGrid(device: device, store: store)
                    }
                    .padding(Space.xl)
                    .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(DevicePresentation.displayName(device.deviceType))
                .alert("Command Failed", isPresented: commandErrorBinding, presenting: store.commandError) { _ in
                    Button("OK", role: .cancel) { store.send(.dismissCommandError) }
                } message: { message in
                    Text(message)
                }
                .sheet(isPresented: travelPreviewBinding) {
                    TravelPlanSheet(store: store)
                }
                .sheet(isPresented: printPreviewBinding) {
                    PrintPlanSheet(
                        preview: store.printPreview,
                        onConfirm: { store.send(.printPreviewConfirmed) },
                        onDismiss: { store.send(.printPreviewDismissed) }
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Device Selected",
                    systemImage: SidebarSymbol.devices,
                    description: Text("Select a device to inspect it.")
                )
            }
        }
        // Keep an in-place-refreshing device live while it's in view: a mining
        // drone's cycle/yield and a diverting propulsor's defense readout both
        // change without a completion event, so the reducer re-reads the device on
        // a cadence keyed to its activity. Stops when the device settles or the
        // selection clears.
        .task(id: refreshKey) {
            store.send(.viewingChanged(deviceCode: refreshKey))
        }
    }

    /// The device to keep refreshing while viewed — its code when it's running an
    /// activity that mutates in place (mining, diverting), else nil (no refresh).
    /// Keying the task on this restarts the loop for a new device and stops it once
    /// the device settles.
    private var refreshKey: String? {
        guard let device = store.selectedDevice else { return nil }
        switch device.statusBase {
        case "mining", "diverting": return device.deviceCode
        default:                    return nil
        }
    }

    /// The fetched diversion snapshot, but only when it belongs to this device's
    /// object — guards against briefly showing a prior selection's snapshot before
    /// the new fetch lands.
    private func diversionSnapshot(for device: Device) -> DiversionSnapshot? {
        guard device.statusBase == "diverting",
              let snapshot = store.diversion,
              snapshot.objectDesignation == device.location
        else { return nil }
        return snapshot
    }

    private var commandErrorBinding: Binding<Bool> {
        Binding(
            get: { store.commandError != nil },
            set: { if !$0 { store.send(.dismissCommandError) } }
        )
    }

    private var travelPreviewBinding: Binding<Bool> {
        Binding(
            get: { store.travelPreview != nil },
            set: { if !$0 { store.send(.travelPreviewDismissed) } }
        )
    }

    private var printPreviewBinding: Binding<Bool> {
        Binding(
            get: { store.printPreview != nil },
            set: { if !$0 { store.send(.printPreviewDismissed) } }
        )
    }

    // MARK: Header

    private func header(_ device: Device) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 0.5)
                    )
                Image.rcSymbol("device.\(device.deviceType)")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.rcTextPrimary, .rcAccent, .rcTextSecondary)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(DevicePresentation.displayName(device.deviceType))
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(1)
                StatusBadge(device.statusBase)
                HStack(spacing: Space.s) {
                    Text(device.deviceCode)
                        .font(.rcMono)
                        .foregroundStyle(.rcTextSecondary)
                        .textSelection(.enabled)
                    if let location = device.location {
                        Text("·").foregroundStyle(.rcTextTertiary)
                        Text(device.locationName ?? location)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: Space.m)
            VStack(spacing: Space.s) {
                CapacityRing(value: device.operationalCapacity)
                Text("Capacity")
                    .font(.rcSectionLabel)
                    .foregroundStyle(.rcTextTertiary)
            }
            .fixedSize()
        }
    }

    // MARK: Readouts — active-task card

    private func readouts(_ device: Device) -> some View {
        ActiveTaskCard(
            operation: openOperation,
            parameter: device.statusParameter,
            liveTravel: device.travelSnapshot,
            diversion: diversionSnapshot(for: device),
            mining: device.statusBase == "mining" ? device.miningSnapshot : nil
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Details

    private func details(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("DETAILS")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)
            detailRow("Replicant", device.replicantCode)
            detailRow("Queue", "\(device.queueSize)")
            if let directive = device.currentDirective {
                detailRow("Directive", DevicePresentation.displayName(directive))
            }
            if !device.features.isEmpty {
                detailRow("Features", device.features.joined(separator: ", "))
            }
            if !device.tags.isEmpty {
                detailRow("Tags", device.tags.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
                )
        )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text(label)
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Capacity ring

private struct CapacityRing: View {
    let value: Double   // 0...100

    private var tone: Color {
        switch value {
        case 66...:  return .rcStatusReady
        case 33..<66: return .rcWarning
        default:     return .rcError
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.rcSeparator, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0, min(1, value / 100)))
                .stroke(tone, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.rcTextPrimary)
                .monospacedDigit()
        }
        .frame(width: 60, height: 60)
    }
}

// MARK: - Active-task card

private struct ActiveTaskCard: View {
    let operation: Operation?
    /// The status parameter the backend appended in parentheses (e.g. the device
    /// type being printed, `"transport_drone"`, or the resource being mined). Shown
    /// beside the task kind instead of crammed into the status badge.
    var parameter: String? = nil
    /// The device's live `travel` block — the fallback route source for a travel
    /// op adopted mid-flight. An op dispatched locally carries its own whole-route
    /// snapshot, frozen at departure, which is preferred.
    var liveTravel: TravelSnapshot? = nil
    /// The defense readout for a `diverting` propulsor, fetched from the object it's
    /// attached to (a diverting device carries no activity block of its own). When
    /// present it replaces the operation readout — diversion isn't a dispatched op.
    var diversion: DiversionSnapshot? = nil
    /// The live mining state for a `mining` drone — resource, cycle, and yield. When
    /// present it replaces the generic operation readout with the cycle-aware card,
    /// since mining is continuous (no deadline) and refreshes in place each cycle.
    var mining: MiningSnapshot? = nil

    /// The itinerary to display for a travel op: the whole route captured at
    /// dispatch when we have it, else the device's remaining-legs snapshot. Nil
    /// for a non-travel op.
    private var itinerary: TravelSnapshot? {
        guard operation?.kind == OperationKind.travel.rawValue else { return nil }
        if let stored = operation?.travelSnapshot, !stored.legs.isEmpty { return stored }
        return liveTravel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("ACTIVE TASK")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)

            if let diversion {
                diversionReadout(diversion)
            } else if let mining {
                miningReadout(mining)
            } else if let operation {
                HStack(spacing: Space.xs) {
                    Text(operation.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.rcHeadline)
                        .foregroundStyle(.rcTextPrimary)
                    if let parameter {
                        Text("·")
                            .font(.rcHeadline)
                            .foregroundStyle(.rcTextTertiary)
                        Text(DevicePresentation.displayName(parameter))
                            .font(.rcHeadline)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
                .lineLimit(1)

                if let itinerary {
                    routeReadout(itinerary)
                }

                progress(for: operation, itinerary: itinerary)
            } else {
                Text("Idle — no active task.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
                )
        )
    }

    /// The progress readout for the operation. A multi-leg travel op gets the
    /// segmented bar; everything else keeps the single interpolated bar. Both are
    /// keyed by op id so the "reached the end" latch resets for a genuinely new
    /// operation (but survives a re-arm of the same one).
    @ViewBuilder
    private func progress(for operation: Operation, itinerary: TravelSnapshot?) -> some View {
        if operation.status == .active, let completesAt = operation.completesAt {
            if let itinerary, !itinerary.legs.isEmpty {
                TravelProgressView(
                    segments: segments(itinerary),
                    barStart: barStart(itinerary, operation: operation, completesAt: completesAt),
                    completesAt: completesAt
                )
                .id(operation.id)
            } else {
                OperationProgressView(startedAt: operation.startedAt, completesAt: completesAt)
                    .id(operation.id)
            }
        } else {
            Text(label(for: operation.status))
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
        }
    }

    private func segments(_ snapshot: TravelSnapshot) -> [TravelBar.Segment] {
        snapshot.legs.map { leg in
            TravelBar.Segment(
                id: leg.index,
                weight: leg.timeSeconds ?? 0,
                type: leg.type,
                from: leg.from,
                to: leg.to
            )
        }
    }

    /// Anchor the sweep on `completesAt − total leg duration` so the fill spans
    /// exactly the legs we can show — the whole trip for a frozen dispatch route,
    /// just the remaining legs for an adopted one. Falls back to the op's start
    /// when the legs carry no durations.
    private func barStart(_ snapshot: TravelSnapshot, operation: Operation, completesAt: Date) -> Date {
        if let total = snapshot.totalLegSeconds, total > 0 {
            return completesAt.addingTimeInterval(-total)
        }
        return operation.startedAt
    }

    private func label(for status: OperationStatus) -> String {
        switch status {
        case .enqueued:   return "Queued — awaiting start."
        case .optimistic: return "Dispatching…"
        default:          return status.rawValue.capitalized
        }
    }

    /// Origin → destination for a travel task.
    private func routeReadout(_ snapshot: TravelSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text(snapshot.originLabel ?? "—")
                .foregroundStyle(.rcTextSecondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.rcTextTertiary)
            Text(snapshot.destinationLabel ?? "—")
                .foregroundStyle(.rcTextPrimary)
        }
        .font(.rcMonoSmall)
        .lineLimit(1)
        .textSelection(.enabled)
    }

    // MARK: Diversion readout

    /// The planetary-defense readout for a diverting propulsor: the threat object,
    /// its deflection progress (a server-authoritative percent, not a timed bar),
    /// and the impact it's averting.
    @ViewBuilder
    private func diversionReadout(_ d: DiversionSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text("Diverting")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
            Text("·")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextTertiary)
            Text(d.objectDesignation)
                .font(.rcMono)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
        }
        .lineLimit(1)

        if let subtitle = objectSubtitle(d) {
            Text(subtitle)
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
        }

        if let pct = d.progressPct {
            VStack(alignment: .leading, spacing: Space.xs) {
                ProgressView(value: min(max(pct / 100, 0), 1))
                    .tint(StatusTone.working.color)
                Text("\(Self.percent(pct)) deflected")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
            }
        }

        VStack(alignment: .leading, spacing: Space.xs) {
            if let impact = impactValue(d) {
                taskRow("Impact", impact)
            }
            if let likelihood = d.impactLikelihood {
                taskRow("Likelihood", Self.percent(likelihood), valueColor: likelihoodColor(likelihood))
            }
            if let thrust = thrustValue(d) {
                taskRow("Thrust", thrust)
            }
        }
        .padding(.top, Space.xs)
    }

    // MARK: Mining readout

    /// The live readout for a mining drone: whether it's extracting or seeking (per
    /// the yield tally), a repeating cycle bar, and the belt/availability/yield.
    @ViewBuilder
    private func miningReadout(_ m: MiningSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text(m.isProducing ? "Mining" : "Seeking")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
            if let resource = m.resourceType {
                Text("·")
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextTertiary)
                Text(DevicePresentation.displayName(resource))
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextSecondary)
            }
        }
        .lineLimit(1)

        Text(m.isProducing ? "Extracting resource" : "Seeking a workable pocket")
            .font(.rcCaption)
            .foregroundStyle(.rcTextTertiary)

        if let started = m.startedAt, let cycle = m.cycleTimeSeconds, cycle > 0 {
            MiningCycleView(startedAt: started, cycleSeconds: cycle)
        }

        VStack(alignment: .leading, spacing: Space.xs) {
            if let belt = beltValue(m) {
                taskRow("Belt", belt)
            }
            if let availability = m.availability {
                taskRow("Resource", DevicePresentation.displayName(availability))
            }
            taskRow("Yield", yieldValue(m))
        }
        .padding(.top, Space.xs)
    }

    /// "ATIANFU-BELT-1 · Dense" — where it's mining and how dense the belt is.
    private func beltValue(_ m: MiningSnapshot) -> String? {
        let density = m.density.map(DevicePresentation.displayName)
        switch (m.belt, density) {
        case let (belt?, density?): return "\(belt) · \(density)"
        case let (belt?, nil):      return belt
        case let (nil, density?):   return density
        default:                    return nil
        }
    }

    /// The uncollected haul: "3 units · 1 cycle", or "none this cycle" when the
    /// last cycle came up empty (the seeking signal).
    private func yieldValue(_ m: MiningSnapshot) -> String {
        let quantity = m.pendingQuantity ?? 0
        let cycles = m.pendingCycles ?? 0
        guard quantity > 0 || cycles > 0 else { return "none this cycle" }
        var parts: [String] = ["\(Self.number(quantity)) unit\(quantity == 1 ? "" : "s")"]
        if cycles > 0 { parts.append("\(cycles) cycle\(cycles == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func taskRow(_ label: String, _ value: String, valueColor: Color = .rcTextSecondary) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text(label)
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.rcMonoSmall)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// "Small Incoming Asteroid" from the object's size class and type.
    private func objectSubtitle(_ d: DiversionSnapshot) -> String? {
        let parts = [d.sizeClass, d.objectType].compactMap { $0 }.map(DevicePresentation.displayName)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "ATIANFU-1 · in 7 days" — where the object strikes and how soon.
    private func impactValue(_ d: DiversionSnapshot) -> String? {
        let eta = d.impactEta.map { $0.formatted(.relative(presentation: .named)) }
        switch (d.impactTarget, eta) {
        case let (target?, eta?): return "\(target) · \(eta)"
        case let (target?, nil): return target
        case let (nil, eta?):     return eta
        default:                  return nil
        }
    }

    /// "1/hr · 24 required · 1 plate" — applied thrust vs. the strength needed.
    private func thrustValue(_ d: DiversionSnapshot) -> String? {
        var parts: [String] = []
        if let thrust = d.currentThrustPerHour { parts.append("\(Self.number(thrust))/hr") }
        if let required = d.requiredStrength { parts.append("\(Self.number(required)) required") }
        if let plates = d.activePlates { parts.append(plates == 1 ? "1 plate" : "\(plates) plates") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A near-certain impact reads as danger, a coin-flip as a warning.
    private func likelihoodColor(_ value: Double) -> Color {
        switch value {
        case 75...:   return .rcError
        case 40..<75: return .rcWarning
        default:      return .rcTextSecondary
        }
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    /// Whole numbers stay whole (`24`), fractions keep one place (`1.5`).
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Command grid + inline parameter panel

private struct CommandGrid: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, for building the `adopt` candidate list (worker devices of
    /// the type this controller shepherds).
    @FetchAll(Device.order { $0.deviceCode }) private var fleet
    /// The unlocked blueprint catalog, backing the `enqueue_print` dropdown.
    @FetchAll(Blueprint.order { $0.deviceType }) private var blueprints
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

    /// The `all` / `none` scope values the survey config dropdowns offer.
    private enum SurveyScope { static let all = "all", none = "none" }

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

    /// The dispatchable subset of the device's available commands. `retarget` is
    /// gated on the device actually mining (the server rejects it otherwise);
    /// `set_directive` only surfaces when the device offers directives, and
    /// `adopt`/`release` only when there are devices to act on — empty pickers
    /// otherwise.
    private var commands: [DeviceCommand] {
        let adopt = adoptCandidates
        let release = releaseCandidates
        return device.availableCommands
            .compactMap {
                DeviceCommand(
                    command: $0,
                    availableDirectives: device.availableDirectives,
                    adoptCandidates: adopt,
                    releaseCandidates: release
                )
            }
            .filter { command in
                switch command {
                case .retarget:               return device.status.lowercased().contains("mining")
                case let .setDirective(opts):  return !opts.isEmpty
                case let .adopt(candidates):   return !candidates.isEmpty
                case let .release(controlled): return !controlled.isEmpty
                default:                      return true
                }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("COMMANDS")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)

            if commands.isEmpty {
                Text("No dispatchable commands for this device yet.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Space.s)], spacing: Space.s) {
                    ForEach(commands) { command in
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

                if let pending {
                    parameterPanel(pending)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Toggle a command's confirm panel, seeding any default parameter value.
    private func select(_ command: DeviceCommand) {
        if pending == command { pending = nil; return }
        textValue = ""
        selectedCodes = []
        if case .print = command {
            // Seed the blueprint picker with the first catalog entry.
            blueprintType = blueprints.first?.deviceType ?? ""
        }
        if case let .choice(_, options) = command.parameter {
            // Seed the directive picker with the device's current directive when
            // it's a valid option, so re-opening reflects what's in force.
            if case .setDirective = command, let current = device.currentDirective, options.contains(current) {
                choiceValue = current
                seedDirectiveConfig()
            } else {
                choiceValue = options.first ?? ""
            }
        } else {
            choiceValue = ""
        }
        pending = command
    }

    /// Seed the survey config controls from the directive currently in force, so
    /// re-opening the picker mirrors what's running. Falls back to the documented
    /// defaults (planets: all, moons: none, recall: on) when no config is present.
    private func seedDirectiveConfig() {
        planetsScope = SurveyScope.all
        moonsScope = SurveyScope.none
        recall = true
        guard device.currentDirective == "survey_system", let config = device.currentDirectiveConfig else { return }
        planetsScope = config["planets"]?.stringValue ?? planetsScope
        moonsScope = config["moons"]?.stringValue ?? moonsScope
        recall = config["recall"]?.boolValue ?? recall
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
                    // selected (survey_system today; other directives take none).
                    if case .setDirective = command {
                        directiveConfiguration(choiceValue)
                    }
                }
            case let .multiSelect(label, options):
                deviceCheckboxList(label, options: options)
            case let .blueprint(label):
                blueprintPicker(label)
            case .none:
                Text("Run \(command.title) on \(device.deviceCode)?")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
            }

            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { pending = nil }
                    .buttonStyle(RCButtonStyle(.secondary))
                // Travel takes an extra beat: preview the dry-run itinerary in a
                // sheet and let the user confirm there. Every other command
                // dispatches straight from here.
                Button(confirmTitle(for: command)) {
                    if command == .travel {
                        store.send(.travelPreviewRequested(
                            deviceCode: device.deviceCode,
                            destination: confirmValue(for: command)
                        ))
                    } else if command == .print {
                        // Print reviews resource cost vs. location stock in a sheet
                        // before enqueuing.
                        store.send(.printPreviewRequested(
                            deviceCode: device.deviceCode,
                            deviceType: blueprintType,
                            location: device.location,
                            locationName: device.locationName,
                            required: requiredLines(for: blueprintType)
                        ))
                    } else {
                        store.send(.commandConfirmed(
                            kind: command.kind,
                            deviceCode: device.deviceCode,
                            params: params(for: command)
                        ))
                    }
                    pending = nil
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
                        .strokeBorder(.rcAccentBorder, lineWidth: 0.5)
                )
        )
    }

    /// The confirm button's title. Travel reviews a route first; adopt shows how
    /// many devices are checked.
    private func confirmTitle(for command: DeviceCommand) -> String {
        if command == .travel { return "Review Route…" }
        if command == .print { return "Review Cost…" }
        if !selectedCodes.isEmpty {
            if case .adopt = command { return "Adopt \(selectedCodes.count)" }
            if case .release = command { return "Release \(selectedCodes.count)" }
        }
        return command.title
    }

    /// The value passed to `params(_:)` for the pending command's parameter kind.
    private func confirmValue(for command: DeviceCommand) -> String {
        switch command.parameter {
        case .text:        return textValue
        case .choice:      return choiceValue
        case .blueprint:   return blueprintType
        case .multiSelect: return ""
        case .none:        return ""
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
        default:
            return command.params(confirmValue(for: command))
        }
    }

    /// The configuration object for a directive, or nil for directives that take
    /// none (belt_search and the rest). Only `survey_system` is configurable today.
    private func directiveConfig(for directive: String) -> [String: JSONValue]? {
        switch directive {
        case "survey_system":
            return [
                "planets": .string(planetsScope),
                "moons": .string(moonsScope),
                "recall": .bool(recall),
            ]
        default:
            return nil
        }
    }

    /// Inline configuration controls for a configurable directive. Empty for
    /// directives that carry no configuration.
    @ViewBuilder
    private func directiveConfiguration(_ directive: String) -> some View {
        if directive == "survey_system" {
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
        }
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

    /// The `adopt` checkbox list: one selectable row per eligible device, capped in
    /// height so a large fleet scrolls rather than pushing the confirm out of view.
    private func deviceCheckboxList(_ label: String, options: [DeviceOption]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label.uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        checkboxRow(option)
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

    /// One device row — a checkbox glyph, the device code, and a status subtitle —
    /// toggling the code in/out of the pending selection.
    private func checkboxRow(_ option: DeviceOption) -> some View {
        let selected = selectedCodes.contains(option.id)
        return Button {
            if selected { selectedCodes.remove(option.id) } else { selectedCodes.insert(option.id) }
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
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
        }
        .buttonStyle(.plain)
    }

    /// Whether the confirm button is enabled — text must be non-empty and a
    /// multi-select needs at least one checked device; choice and confirm-only
    /// commands are always ready.
    private func isConfirmable(_ command: DeviceCommand) -> Bool {
        switch command.parameter {
        case .text:        return !textValue.trimmingCharacters(in: .whitespaces).isEmpty
        case .choice:      return !choiceValue.isEmpty
        case .blueprint:   return !blueprintType.isEmpty
        case .multiSelect: return !selectedCodes.isEmpty
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

// MARK: - Travel itinerary sheet (dry-run preview)

/// The confirmation sheet for a `travel` command: shows the dry-run itinerary
/// (legs + totals) and lets the user commit or back out. Reads the live preview
/// off the store so the loading → loaded/failed transition animates in place.
private struct TravelPlanSheet: View {
    let store: StoreOf<DevicesFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if let preview = store.travelPreview {
                header(preview)
                Divider().overlay(Color.rcSeparator)
                content(preview)
                footer(preview)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
        .background(Color.rcContentBackground)
    }

    // MARK: Header

    private func header(_ preview: DevicesFeature.TravelPreview) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "location.north.line")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.rcAccent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Travel Itinerary")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                HStack(spacing: Space.xs) {
                    Text(preview.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.rcTextTertiary)
                    Text(preview.destination)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Phase-driven content

    @ViewBuilder
    private func content(_ preview: DevicesFeature.TravelPreview) -> some View {
        switch preview.phase {
        case .loading:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Plotting route…")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)

        case let .failed(message):
            VStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.rcWarning)
                Text(message)
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 120)

        case let .loaded(plan):
            VStack(alignment: .leading, spacing: Space.l) {
                summary(plan)
                routeList(plan)
            }
        }
    }

    // MARK: Loaded — summary + legs

    private func summary(_ plan: TravelPlan) -> some View {
        HStack(spacing: Space.s) {
            summaryTile("Time", plan.totalTimeSeconds.map(Self.duration) ?? "—")
            if let ly = plan.totalDistanceLy, ly > 0 {
                summaryTile("Distance", Self.distanceLy(ly))
            }
            summaryTile("Legs", "\(plan.route.count)")
            if let type = plan.destinationType {
                summaryTile("Arrival", type.capitalized)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryTile(_ label: String, _ value: String) -> some View {
        VStack(spacing: Space.xs) {
            Text(value)
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.rcSectionLabel).kerning(0.5)
                .foregroundStyle(.rcTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
                )
        )
    }

    private func routeList(_ plan: TravelPlan) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("ROUTE")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)
            VStack(spacing: 0) {
                ForEach(Array(plan.route.enumerated()), id: \.offset) { index, leg in
                    if index > 0 { Divider().overlay(Color.rcSeparator) }
                    legRow(leg, number: index + 1)
                }
            }
            .padding(.vertical, Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 0.5)
                    )
            )
        }
    }

    private func legRow(_ leg: TravelPlan.Leg, number: Int) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            Text("\(leg.leg ?? number)")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(leg.from ?? "—")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.rcTextTertiary)
                    Text(leg.to ?? "—")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextPrimary)
                }
                if let type = leg.type {
                    Text(type.capitalized)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            Spacer(minLength: Space.s)

            VStack(alignment: .trailing, spacing: 2) {
                if let seconds = leg.timeSeconds {
                    Text(Self.duration(seconds))
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                        .monospacedDigit()
                }
                Text(Self.legDistance(leg))
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ preview: DevicesFeature.TravelPreview) -> some View {
        HStack(spacing: Space.s) {
            Spacer()
            switch preview.phase {
            case .loaded:
                Button("Cancel") { store.send(.travelPreviewDismissed) }
                    .buttonStyle(RCButtonStyle(.secondary))
                Button("Confirm Travel") { store.send(.travelPreviewConfirmed) }
                    .buttonStyle(RCButtonStyle(.primary))
            case .failed:
                Button("Close") { store.send(.travelPreviewDismissed) }
                    .buttonStyle(RCButtonStyle(.secondary))
            case .loading:
                Button("Cancel") { store.send(.travelPreviewDismissed) }
                    .buttonStyle(RCButtonStyle(.secondary))
            }
        }
    }

    // MARK: Formatting

    /// Whole-second duration: `"50s"`, `"2m 6s"`, `"2m"`.
    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    private static func distanceLy(_ ly: Double) -> String {
        String(format: "%.2f ly", ly)
    }

    /// A leg's distance — light-years for an interstellar hop, AU within a system.
    private static func legDistance(_ leg: TravelPlan.Leg) -> String {
        if let ly = leg.distanceLy { return String(format: "%.2f ly", ly) }
        if let au = leg.distanceAu { return String(format: "%.2f AU", au) }
        return "—"
    }
}
