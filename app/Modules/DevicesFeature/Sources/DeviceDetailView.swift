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

import ComposableArchitecture
import DependencyClients
import IssueReporting
import SQLiteData
import SwiftUI
import UI

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

public struct DeviceDetailView: View {
    let store: StoreOf<DevicesFeature>
    /// Loaded lazily by the selection `.task(id:)` below so the query tracks the
    /// selected device code rather than fetching the whole fleet to filter it.
    @FetchOne(Device.none) private var device: Device?
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
            if let device {
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
            } else {
                ContentUnavailableView(
                    "No Device Selected",
                    systemImage: SidebarSymbol.devices,
                    description: Text("Select a device to inspect it.")
                )
            }
        }
        // Reload the single-row query whenever the selected device changes.
        .task(id: store.selectedDeviceCode) {
            _ = await withErrorReporting {
                try await $device.load(
                    Device.where { $0.deviceCode.eq(store.selectedDeviceCode ?? "") },
                    animation: .default
                )
            }
        }
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
                StatusBadge(device.status)
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
        ActiveTaskCard(operation: openOperation)
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
            VStack(spacing: 0) {
                Text("\(Int(value))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.rcTextPrimary)
                    .monospacedDigit()
                Text("%").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
        }
        .frame(width: 60, height: 60)
    }
}

// MARK: - Active-task card

private struct ActiveTaskCard: View {
    let operation: Operation?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("ACTIVE TASK")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)

            if let operation {
                Text(operation.kind.capitalized)
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextPrimary)

                if operation.status == .active,
                   let completesAt = operation.completesAt {
                    // Keyed by op id so the progress view's "reached the end" state
                    // resets for a genuinely new operation (but survives a re-arm of
                    // the same one).
                    OperationProgressView(startedAt: operation.startedAt, completesAt: completesAt)
                        .id(operation.id)
                } else {
                    Text(label(for: operation.status))
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextSecondary)
                }
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

    private func label(for status: OperationStatus) -> String {
        switch status {
        case .enqueued:   return "Queued — awaiting start."
        case .optimistic: return "Dispatching…"
        default:          return status.rawValue.capitalized
        }
    }
}

// MARK: - Command grid + inline parameter panel

private struct CommandGrid: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    @State private var pending: DeviceCommand?
    @State private var textValue: String = ""
    @State private var choiceValue: String = ""

    /// The dispatchable subset of the device's available commands. `retarget` is
    /// gated on the device actually mining — the server rejects it otherwise.
    private var commands: [DeviceCommand] {
        device.availableCommands
            .compactMap(DeviceCommand.init(command:))
            .filter { $0 != .retarget || device.status.lowercased().contains("mining") }
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
        if case let .choice(_, options) = command.parameter {
            choiceValue = options.first ?? ""
        } else {
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
                Button(command == .travel ? "Review Route…" : command.title) {
                    if command == .travel {
                        store.send(.travelPreviewRequested(
                            deviceCode: device.deviceCode,
                            destination: confirmValue(for: command)
                        ))
                    } else {
                        store.send(.commandConfirmed(
                            kind: command.kind,
                            deviceCode: device.deviceCode,
                            params: command.params(confirmValue(for: command))
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

    /// The value passed to `params(_:)` for the pending command's parameter kind.
    private func confirmValue(for command: DeviceCommand) -> String {
        switch command.parameter {
        case .text:   return textValue
        case .choice: return choiceValue
        case .none:   return ""
        }
    }

    /// Whether the confirm button is enabled — text must be non-empty; choice and
    /// confirm-only commands are always ready.
    private func isConfirmable(_ command: DeviceCommand) -> Bool {
        switch command.parameter {
        case .text:   return !textValue.trimmingCharacters(in: .whitespaces).isEmpty
        case .choice: return !choiceValue.isEmpty
        case .none:   return true
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
