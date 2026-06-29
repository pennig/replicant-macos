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
import SQLiteData
import SwiftUI
import UI

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

public struct DeviceDetailView: View {
    let store: StoreOf<DevicesFeature>
    @FetchAll(Device.all) private var devices
    @FetchAll(Operation.order { $0.startedAt.desc() }) private var operations

    public init(store: StoreOf<DevicesFeature>) {
        self.store = store
    }

    private var device: Device? {
        guard let code = store.selectedDeviceCode else { return nil }
        return devices.first { $0.deviceCode == code }
    }

    /// The device's single open operation, if any.
    private var openOperation: Operation? {
        guard let code = store.selectedDeviceCode else { return nil }
        return operations.first {
            $0.entityCode == code
                && ($0.status == OperationStatus.active.rawValue
                    || $0.status == OperationStatus.enqueued.rawValue
                    || $0.status == OperationStatus.optimistic.rawValue)
        }
    }

    public var body: some View {
        if let device {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header(device)
                    readouts(device)
                    details(device)
                    CommandGrid(device: device, store: store)
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(DevicePresentation.displayName(device.deviceType))
            .alert("Command Failed", isPresented: commandErrorBinding, presenting: store.commandError) { _ in
                Button("OK", role: .cancel) { store.send(.dismissCommandError) }
            } message: { message in
                Text(message)
            }
        } else {
            ContentUnavailableView(
                "No Device Selected",
                systemImage: SidebarSymbol.devices,
                description: Text("Select a device to inspect it.")
            )
        }
    }

    private var commandErrorBinding: Binding<Bool> {
        Binding(
            get: { store.commandError != nil },
            set: { if !$0 { store.send(.dismissCommandError) } }
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
                Image(systemName: DevicePresentation.symbol(for: device.deviceType))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.rcAccent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(DevicePresentation.displayName(device.deviceType))
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                StatusBadge(device.status)
                HStack(spacing: Space.s) {
                    Text(device.deviceCode)
                        .font(.rcMono)
                        .foregroundStyle(.rcTextSecondary)
                    if let location = device.location {
                        Text("·").foregroundStyle(.rcTextTertiary)
                        Text(device.locationName ?? location)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Readouts — capacity ring + active-task card

    private func readouts(_ device: Device) -> some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(spacing: Space.s) {
                CapacityRing(value: device.operationalCapacity)
                Text("Capacity")
                    .font(.rcSectionLabel)
                    .foregroundStyle(.rcTextTertiary)
            }
            ActiveTaskCard(operation: openOperation)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.rcTextPrimary)
                    .monospacedDigit()
                Text("%").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
        }
        .frame(width: 88, height: 88)
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

                if operation.status == OperationStatus.active.rawValue,
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

    private func label(for status: String) -> String {
        switch status {
        case OperationStatus.enqueued.rawValue:   return "Queued — awaiting start."
        case OperationStatus.optimistic.rawValue: return "Dispatching…"
        default:                                  return status.capitalized
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
                Button(command.title) {
                    store.send(.commandConfirmed(
                        kind: command.kind,
                        deviceCode: device.deviceCode,
                        params: command.params(confirmValue(for: command))
                    ))
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
