//
//  DeviceDetailView.swift
//  Replicould — Devices feature
//
//  The device inspector for the split view's detail column: header, an
//  operational-capacity ring, an active-task card (live progress + ETA from the
//  device's open `Operation`, interpolated with zero network by
//  `OperationProgressView`), a details readout, and a command grid whose
//  parameterized commands (travel / print) reveal an inline confirm panel.
//  Everything observes SQLite, so a stream update or a dispatched op re-renders
//  the pane automatically.
//

import ComposableArchitecture
import GameModels
import GameServices
import IssueReporting
import PrintingUI
import SQLiteData
import SwiftUI
import TravelUI
import UI
import UniverseModels
import Utils

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

public struct DeviceDetailView: View {
    let store: StoreOf<DevicesFeature>
    @FetchAll(Operation.order { $0.startedAt.desc() }) private var operations
    @FetchAll(Replicant.all) private var replicants
    @Environment(\.scenePhase) private var scenePhase

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
                        if device.features.contains("attach") {
                            AttachedDevicesSection(device: device, store: store)
                        }
                        if device.stowCapacity > 0 {
                            StowedDevicesSection(device: device, store: store)
                        }
                        if device.features.contains("transport") {
                            CargoSection(device: device)
                        }
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
                // Item-driven (not `isPresented:`) so back-to-back previews for
                // different devices re-present reliably: keyed on the preview's
                // identity, SwiftUI dismisses one device's sheet and presents the
                // next even when the swap lands mid-dismiss-animation — a bool
                // toggled off→on in that window is silently coalesced and dropped.
                // Content reads `store.travelPreview` live so the loading→loaded
                // phase transition still renders.
                .sheet(item: travelPreviewItem) { _ in
                    TravelPlanSheet(
                        preview: store.travelPreview,
                        onConfirm: { store.send(.travelPreviewConfirmed) },
                        onDismiss: { store.send(.travelPreviewDismissed) }
                    )
                }
                .sheet(item: printPreviewItem) { _ in
                    PrintPlanSheet(
                        preview: store.printPreview,
                        onConfirm: { store.send(.printPreviewConfirmed) },
                        onDismiss: { store.send(.printPreviewDismissed) }
                    )
                }
                .sheet(item: cargoLoadItem) { _ in
                    CargoLoadSheet(
                        preview: store.cargoLoad,
                        onConfirm: { store.send(.cargoLoadConfirmed(resources: $0)) },
                        onDismiss: { store.send(.cargoLoadDismissed) }
                    )
                }
            } else {
                RCContentUnavailableView(
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
        // The staleness tracker's visible set follows the *selection*, not the
        // refresh key — every inspected device is visible, not just the ones
        // running a refreshable activity (a settled device must still spend its
        // marks promptly while on screen).
        .task(id: store.selectedDeviceCode) {
            store.send(.inspectorVisibilityChanged(deviceCode: store.selectedDeviceCode))
        }
        // `.task(id:)` only restarts the loop across *selection* changes. When
        // the view is REMOVED (sidebar category switch, window close), SwiftUI
        // cancels the view task but the store's refresh effect would keep
        // polling the hidden device — forever, for mining/diverting devices
        // that never settle (V3.4-B1). Teardown must say so explicitly.
        .onDisappear {
            store.send(.viewingChanged(deviceCode: nil))
            store.send(.inspectorVisibilityChanged(deviceCode: nil))
        }
        // Likewise a backgrounded/hidden app shouldn't spend reads on an
        // inspector nobody can see; the loop resumes with the scene. Only
        // `.background` definitively means "not visible" on macOS — `.inactive`
        // can be reported while the window is still fully on screen (app merely
        // resigned active, exactly the watch-a-mining-op-beside-a-browser case),
        // so it must neither stop nor restart the loop.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store.send(.viewingChanged(deviceCode: nil))
                store.send(.inspectorVisibilityChanged(deviceCode: nil))
            case .active:
                store.send(.viewingChanged(deviceCode: refreshKey))
                store.send(.inspectorVisibilityChanged(deviceCode: store.selectedDeviceCode))
            default:
                break
            }
        }
    }

    /// The device to keep refreshing while viewed — its code when it's running an
    /// activity that mutates in place (mining, diverting), else nil (no refresh).
    /// Keying the task on this restarts the loop for a new device and stops it once
    /// the device settles.
    private var refreshKey: String? {
        guard let device = store.selectedDevice else { return nil }
        switch device.statusBase {
        case "mining", "diverting", "repairing": return device.deviceCode
        default:                                 return nil
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

    /// Item bindings for the preview sheets: SwiftUI presents while the value is
    /// non-nil and keys re-presentation on the item's identity; a nil write (the
    /// user closing the sheet) routes to the dismiss action.
    private var travelPreviewItem: Binding<TravelPreview?> {
        Binding(
            get: { store.travelPreview },
            set: { if $0 == nil { store.send(.travelPreviewDismissed) } }
        )
    }

    private var printPreviewItem: Binding<PrintPreview?> {
        Binding(
            get: { store.printPreview },
            set: { if $0 == nil { store.send(.printPreviewDismissed) } }
        )
    }

    private var cargoLoadItem: Binding<CargoLoadPreview?> {
        Binding(
            get: { store.cargoLoad },
            set: { if $0 == nil { store.send(.cargoLoadDismissed) } }
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
            mining: device.statusBase == "mining" ? device.miningSnapshot : nil,
            repair: device.statusBase == "repairing" ? device.repairSnapshot : nil
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Details

    private func details(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Details")
            replicantRow(device)
            if device.features.contains("print") {
                detailRow("Queue capacity", "\(device.queueSize)")
            }
            if let directive = device.currentDirective {
                detailRow("Directive", DevicePresentation.displayName(directive))
                directiveSummaryRows(directive, device: device)
            }
            if !device.features.isEmpty {
                detailRow("Features", device.features.joined(separator: ", "))
            }
            TagsEditor(device: device, store: store)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                )
        )
    }

    /// Supplemental detail rows summarising an in-force transport directive's
    /// configuration — the route it runs, its resource priority, or its one-shot
    /// delivery target. Nothing for directives without a route (survey/mining).
    @ViewBuilder
    private func directiveSummaryRows(_ directive: String, device: Device) -> some View {
        let config = device.currentDirectiveConfig
        switch directive {
        case "delivery":
            if let collect = config?["route"]?["collect"]?.stringValue,
               let deliver = config?["route"]?["deliver"]?.stringValue {
                detailRow("Route", "\(collect) → \(deliver)")
            }
            if let target = requirementSummary(config?["requirement"]) {
                detailRow("Target", target)
            }
        case "shuttle", "ferry":
            if let collect = config?["collect"]?.stringValue,
               let deliver = config?["deliver"]?.stringValue {
                detailRow("Route", "\(collect) → \(deliver)")
            }
            if let priority = prioritySummary(config?["priority"]) {
                detailRow("Priority", priority)
            }
        case "consolidate":
            if let deliver = config?["deliver"]?.stringValue {
                detailRow("Deliver to", deliver)
            }
            if let priority = prioritySummary(config?["priority"]) {
                detailRow("Priority", priority)
            }
        default:
            EmptyView()
        }
    }

    /// "carbon 50 · silicates 100" from a `delivery` requirement object, or nil
    /// when it's absent or empty.
    private func requirementSummary(_ value: JSONValue?) -> String? {
        guard case let .object(target)? = value, !target.isEmpty else { return nil }
        let parts = target
            .compactMap { key, amount -> String? in
                guard let n = amount.numberValue else { return nil }
                let formatted = n == n.rounded() ? String(Int(n)) : String(n)
                return "\(key) \(formatted)"
            }
            .sorted()
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "carbon → rares" from a `priority` array (order preserved), or nil when
    /// it's absent or empty.
    private func prioritySummary(_ value: JSONValue?) -> String? {
        let resources = value?.arrayValue?.compactMap(\.stringValue) ?? []
        return resources.isEmpty ? nil : resources.joined(separator: " → ")
    }

    /// The device's host replicant name from the roster, if known.
    private func replicantName(for device: Device) -> String? {
        let name = replicants.first { $0.replicantCode == device.replicantCode }?.name
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The "Replicant" readout: the host's name in a proportional font followed by
    /// its code in mono, falling back to just the code when the name is unknown.
    private func replicantRow(_ device: Device) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text("Replicant")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 80, alignment: .leading)
            Text(replicantValue(device))
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// The replicant value run: "{name} " proportional + "({code})" mono, or just
    /// the code in mono when the host name is unknown.
    private func replicantValue(_ device: Device) -> AttributedString {
        var code = AttributedString(device.replicantCode)
        code.font = .rcMonoSmall
        guard let name = replicantName(for: device) else { return code }
        var namePart = AttributedString("\(name) ")
        namePart.font = .rcCaption
        var codePart = AttributedString("(")
        codePart.append(code)
        codePart.append(AttributedString(")"))
        codePart.font = .rcMonoSmall
        return namePart + codePart
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
