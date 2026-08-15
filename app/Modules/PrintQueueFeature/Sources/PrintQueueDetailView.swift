//
//  PrintQueueDetailView.swift
//  Replicould — Printing feature
//
//  The printer inspector for the split view's detail column: the active job with
//  a live progress bar (interpolated on device by `OperationProgressView`), any
//  resources a queued job is still waiting on, the queue itself (each entry
//  removable via `dequeue_print`), and an enqueue field to add a new job. Reads
//  everything straight from the device's `printing` / `print_queue` /
//  `waiting_for` blocks, so a stream update re-renders the pane automatically.
//

import ComposableArchitecture
import GameModels
import GameServices
import PrintingUI
import SQLiteData
import SwiftUI
import UI

public struct PrintQueueDetailView: View {
    let store: StoreOf<PrintQueueFeature>
    /// The unlocked blueprint catalog, backing the enqueue dropdown.
    @FetchAll(Blueprint.order { $0.deviceType }) private var blueprints

    /// The selected blueprint's `device_type` for the enqueue dropdown.
    @State private var enqueueType: String = ""

    public init(store: StoreOf<PrintQueueFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let device = store.selectedDevice {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        header(device)
                        activeJob(device)
                        waitingFor(device)
                        queue(device)
                        enqueue(device)
                    }
                    .padding(Space.xl)
                    .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(PrintQueuePresentation.displayName(device.deviceType))
                .alert("Command Failed", isPresented: commandErrorBinding, presenting: store.commandError) { _ in
                    Button("OK", role: .cancel) { store.send(.dismissCommandError) }
                } message: { message in
                    Text(message)
                }
                .sheet(item: printPreviewItem) { _ in
                    PrintPlanSheet(
                        preview: store.printPreview,
                        onConfirm: { store.send(.printPreviewConfirmed) },
                        onDismiss: { store.send(.printPreviewDismissed) }
                    )
                }
            } else {
                RCContentUnavailableView(
                    "No Printer Selected",
                    systemImage: "printer",
                    description: Text("Select a printer to inspect its job and queue.")
                )
            }
        }
        // Keep the enqueue selection valid as the catalog loads.
        .onChange(of: blueprints.map(\.deviceType)) { _, types in
            if !types.contains(enqueueType) { enqueueType = types.first ?? "" }
        }
    }

    private var commandErrorBinding: Binding<Bool> {
        Binding(
            get: { store.commandError != nil },
            set: { if !$0 { store.send(.dismissCommandError) } }
        )
    }

    // `item:`, not `isPresented:` — rapid back-to-back presentations drop the
    // dialog under the boolean form (see the preview-sheet memory note); the
    // other three preview-sheet call sites were already converted.
    private var printPreviewItem: Binding<PrintPreview?> {
        Binding(
            get: { store.printPreview },
            set: { if $0 == nil { store.send(.printPreviewDismissed) } }
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
                            .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                    )
                Image.rcSymbol("device.\(device.deviceType)")
                    .font(.system(size: IconSize.hero, weight: .regular))
                    .foregroundStyle(.rcTextPrimary, .rcAccent, .rcTextSecondary)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(PrintQueuePresentation.displayName(device.deviceType))
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(1)
                StatusBadge(device.statusBase, parameter: device.statusParameter.map(PrintQueuePresentation.displayName))
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
        }
    }

    // MARK: Active job

    @ViewBuilder
    private func activeJob(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Active Job")

            if let printing = device.printingSnapshot {
                HStack(spacing: Space.xs) {
                    Text("Printing")
                        .font(.rcHeadline)
                        .foregroundStyle(.rcTextPrimary)
                    if let target = printing.deviceType {
                        Text("·")
                            .font(.rcHeadline)
                            .foregroundStyle(.rcTextTertiary)
                        Text(PrintQueuePresentation.displayName(target))
                            .font(.rcHeadline)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
                .lineLimit(1)

                // Live interpolated bar when the job reports both endpoints; else
                // fall back to the server's progress percent.
                if let started = printing.startedAt, let completes = printing.completesAt {
                    OperationProgressView(startedAt: started, completesAt: completes)
                        .id(device.deviceCode + (printing.deviceType ?? ""))
                } else if let pct = printing.progressPercent {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ProgressView(value: min(max(pct / 100, 0), 1))
                            .tint(.rcAccent)
                        Text(String(format: "%.0f%%", pct))
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
            } else {
                Text("Idle — no job on the platen.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(Space.m)
        .background(cardBackground)
    }

    // MARK: Waiting-for resources

    @ViewBuilder
    private func waitingFor(_ device: Device) -> some View {
        let resources = device.waitingForResources
        if !resources.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                RCSectionHeader("Waiting For")
                ForEach(resources) { resource in
                    HStack(alignment: .top, spacing: Space.m) {
                        Image(systemName: resource.isMet ? "checkmark.circle.fill" : "hourglass")
                            .font(.system(size: IconSize.s))
                            .foregroundStyle(resource.isMet ? Color.rcStatusReady : .rcWarning)
                        Text(
                            resource.kind == .component
                                ? BlueprintPresentation.displayName(resource.resource)
                                : PrintQueuePresentation.displayName(resource.resource)
                        )
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                            .frame(width: 120, alignment: .leading)
                        Text(Self.amountText(resource))
                            .font(.rcMonoSmall)
                            .foregroundStyle(resource.isMet ? .rcTextSecondary : .rcTextPrimary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.m)
            .background(cardBackground)
        }
    }

    // MARK: Queue

    @ViewBuilder
    private func queue(_ device: Device) -> some View {
        let items = device.printQueueItems
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                RCSectionHeader("Queue")
                Spacer(minLength: 0)
                if !items.isEmpty {
                    Button(role: .destructive) {
                        store.send(.commandConfirmed(
                            kind: .simple("clear_queue"),
                            deviceCode: device.deviceCode,
                            params: CommandParams()
                        ))
                    } label: {
                        Label("Clear", systemImage: "trash.slash")
                    }
                    .buttonStyle(RCButtonStyle(.text))
                    .help("Clear all queued jobs")
                }
            }

            if items.isEmpty {
                Text("No jobs queued.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if item.index > 0 { Divider().overlay(Color.rcSeparator) }
                        queueRow(item, deviceCode: device.deviceCode)
                    }
                }
                .background(cardBackground)
            }
        }
    }

    private func queueRow(_ item: PrintQueueItem, deviceCode: String) -> some View {
        HStack(spacing: Space.m) {
            Text("\(item.index + 1)")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(PrintQueuePresentation.displayName(item.deviceType ?? "Unknown"))
                    .font(.rcBody)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(1)
                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: ", "))
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.s)
            Button(role: .destructive) {
                store.send(.commandConfirmed(
                    kind: .dequeuePrint,
                    deviceCode: deviceCode,
                    params: CommandParams(index: item.index)
                ))
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(.rcTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    // MARK: Enqueue

    @ViewBuilder
    private func enqueue(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Enqueue Print")
            if blueprints.isEmpty {
                Text("No blueprints unlocked yet.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            } else {
                HStack(spacing: Space.s) {
                    RCValueSelect(
                        "Blueprint",
                        options: blueprints.map {
                            (label: PrintQueuePresentation.displayName($0.deviceType), value: $0.deviceType)
                        },
                        selection: $enqueueType
                    )
                    Spacer(minLength: 0)
                    Button("Review Cost…") {
                        store.send(.printPreviewRequested(
                            deviceCode: device.deviceCode,
                            deviceType: enqueueType,
                            location: device.location,
                            locationName: device.locationName,
                            required: requiredLines(for: enqueueType)
                        ))
                    }
                    .buttonStyle(RCButtonStyle(.primary))
                    .disabled(enqueueType.isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(cardBackground)
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

    // MARK: Shared chrome

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
    }

    /// "3 / 5" — how much of a waiting resource the location has vs. needs.
    private static func amountText(_ resource: WaitingResource) -> String {
        let have = resource.have.map(number) ?? "—"
        let need = resource.need.map(number) ?? "—"
        return "\(have) / \(need)"
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Presentation

/// View-side display helpers for the Print Queue. Mirrors `DevicePresentation`
/// (which is internal to the Devices feature) so this module can render device
/// type names without a cross-feature dependency.
enum PrintQueuePresentation {
    /// "heaven_vessel" → "HEAVEN Vessel". Delegates to the shared GameModels
    /// helper so the special-casing rules live in one place.
    static func displayName(_ raw: String) -> String {
        BlueprintPresentation.displayName(raw)
    }
}
