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
            mining: device.statusBase == "mining" ? device.miningSnapshot : nil,
            repair: device.statusBase == "repairing" ? device.repairSnapshot : nil
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
            detailRow("Queue capacity", "\(device.queueSize)")
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
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
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

// MARK: - Tags editor

/// The editable "Tags" row in the details card: the device's current tags as
/// removable chips plus an inline field to add one. Every edit sends the *whole*
/// new set through `.tagsEdited` (the PATCH replaces all tags at once); the chips
/// update once the authoritative device row reconciles back, so they reflect
/// confirmed state rather than an optimistic guess.
private struct TagsEditor: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    @State private var newTag: String = ""
    @FocusState private var focused: Bool

    private var trimmedTag: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Enabled once the field holds a non-empty tag the device doesn't already carry.
    private var canAdd: Bool { !trimmedTag.isEmpty && !device.tags.contains(trimmedTag) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text("Tags")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.s) {
                if !device.tags.isEmpty {
                    FlowLayout(spacing: Space.xs) {
                        ForEach(device.tags, id: \.self) { tag in
                            chip(tag)
                        }
                    }
                }
                addField
            }
            Spacer(minLength: 0)
        }
    }

    /// One removable tag chip — the tag text with a trailing ✕ that drops it.
    private func chip(_ tag: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(tag)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
            Button {
                remove(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.rcTextTertiary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(.rcSurfaceRaisedStrong, in: Capsule())
        .overlay(Capsule().strokeBorder(.rcSeparator, lineWidth: 0.5))
    }

    /// The inline add-a-tag field: a compact input with a + affordance, committing
    /// on Return or the button.
    private var addField: some View {
        HStack(spacing: Space.xs) {
            TextField("Add tag…", text: $newTag)
                .textFieldStyle(.plain)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextPrimary)
                .focused($focused)
                .onSubmit(commit)
            Button {
                commit()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(canAdd ? Color.rcAccent : .rcTextTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add tag")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, Space.s)
        .frame(maxWidth: 200)
        .background(.rcSurfaceRaisedStrong, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(focused ? Color.rcAccentBorder : .rcSeparator, lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private func commit() {
        let tag = trimmedTag
        newTag = ""
        guard !tag.isEmpty, !device.tags.contains(tag) else { return }
        store.send(.tagsEdited(deviceCode: device.deviceCode, tags: device.tags + [tag]))
    }

    private func remove(_ tag: String) {
        store.send(.tagsEdited(deviceCode: device.deviceCode, tags: device.tags.filter { $0 != tag }))
    }
}

/// A minimal flow layout: lays subviews left-to-right, wrapping to the next row
/// when the proposed width is exceeded.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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
    /// The live repair state for a `repairing` bot — target device, server progress,
    /// and ETA. When present it replaces the generic operation readout, since repair
    /// carries its state in the device's own `repair` block and refreshes in place.
    var repair: RepairSnapshot? = nil

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
            } else if let repair {
                repairReadout(repair)
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
            if let mined = m.quantityMined, mined > 0 {
                taskRow("Session", "\(Self.number(mined)) unit\(mined == 1 ? "" : "s") mined")
            }
        }
        .padding(.top, Space.xs)
    }

    // MARK: Repair readout

    /// The live readout for a repairing bot: the device it's mending, a progress
    /// bar (live-interpolated from `started_at`/`eta_seconds` when both are known,
    /// else the server's authoritative percent), and the completion percent.
    @ViewBuilder
    private func repairReadout(_ r: RepairSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text("Repairing")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
            if let target = r.targetDeviceCode {
                Text("·")
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextTertiary)
                Text(target)
                    .font(.rcMono)
                    .foregroundStyle(.rcTextSecondary)
                    .textSelection(.enabled)
            }
        }
        .lineLimit(1)

        if let started = r.startedAt, let completesAt = r.completesAt {
            OperationProgressView(startedAt: started, completesAt: completesAt, tint: StatusTone.working.color)
        } else if let pct = r.progressPercent {
            ProgressView(value: min(max(pct / 100, 0), 1))
                .tint(StatusTone.working.color)
        }

        if let pct = r.progressPercent {
            VStack(alignment: .leading, spacing: Space.xs) {
                taskRow("Progress", "\(Self.percent(pct)) complete")
            }
            .padding(.top, Space.xs)
        }
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

// MARK: - Attached devices

/// The roster of devices currently attached to a carrier (a vessel with the
/// `attach` feature). The codes come from the carrier's `attached_devices` tail;
/// each is resolved against the observed fleet so the row can show the device's
/// type, status, and location. Tapping a row selects that device in the inspector.
/// Shown only for carriers; an empty carrier still renders the section with its
/// capacity so the affordance to attach is discoverable.
private struct AttachedDevicesSection: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, so each attached code can be resolved to its full record.
    @FetchAll(Device.order { $0.deviceCode }) private var fleet

    /// The attached devices, resolved to full records where the fleet knows them.
    /// An unknown code (not yet loaded) still yields a row so the count is honest.
    private var attached: [(code: String, device: Device?)] {
        device.attachedDeviceCodes.map { code in
            (code, fleet.first { $0.deviceCode == code })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text("ATTACHED DEVICES")
                    .font(.rcSectionLabel).kerning(1)
                    .foregroundStyle(.rcTextTertiary)
                Spacer(minLength: 0)
                if device.attachCapacity > 0 {
                    Text("\(attached.count)/\(device.attachCapacity)")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            if attached.isEmpty {
                Text("No devices attached.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(attached.enumerated()), id: \.element.code) { index, entry in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        row(code: entry.code, attached: entry.device)
                    }
                }
                .background(cardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One attached-device row — glyph, display name + code, and a status badge
    /// with its location. Selects the device in the inspector when tapped.
    @ViewBuilder
    private func row(code: String, attached: Device?) -> some View {
        Button {
            store.send(.binding(.set(\.selectedDeviceCode, code)))
        } label: {
            HStack(spacing: Space.s) {
                RCGlyphTile(Image.rcSymbol("device.\(attached?.deviceType ?? "unknown")"))
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(attached.map { DevicePresentation.displayName($0.deviceType) } ?? "Attached Device")
                            .font(.rcBodyEmph)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                        Text(code)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                    if let attached {
                        HStack(spacing: Space.s) {
                            StatusBadge(attached.statusBase)
                            if let location = attached.location {
                                Text(attached.locationName ?? location)
                                    .font(.rcMonoSmall)
                                    .foregroundStyle(.rcTextTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.rcTextTertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: 0.5)
            )
    }
}

// MARK: - Stowed devices

/// The roster of devices currently stowed inside a carrier (one whose
/// `stow_capacity` is greater than zero). The codes come from the carrier's
/// `stowed_devices` tail; each is resolved against the observed fleet so the row
/// can show the device's type, status, and location. Tapping a row selects that
/// device in the inspector. The header reports how many slots remain free
/// (`stow_capacity − stow_used`); an empty carrier still renders the section so
/// its available capacity is discoverable.
private struct StowedDevicesSection: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    /// The whole fleet, so each stowed code can be resolved to its full record.
    @FetchAll(Device.order { $0.deviceCode }) private var fleet

    /// The stowed devices, resolved to full records where the fleet knows them. An
    /// unknown code (not yet loaded) still yields a row so the count is honest.
    private var stowed: [(code: String, device: Device?)] {
        device.stowedDeviceCodes.map { code in
            (code, fleet.first { $0.deviceCode == code })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text("STOWED DEVICES")
                    .font(.rcSectionLabel).kerning(1)
                    .foregroundStyle(.rcTextTertiary)
                Spacer(minLength: 0)
                Text("\(device.stowUsed)/\(device.stowCapacity) · \(device.stowRemaining) free")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

            if stowed.isEmpty {
                Text("No devices stowed.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stowed.enumerated()), id: \.element.code) { index, entry in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        row(code: entry.code, stowed: entry.device)
                    }
                }
                .background(cardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One stowed-device row — glyph, display name + code, and a status badge with
    /// its location. Selects the device in the inspector when tapped.
    @ViewBuilder
    private func row(code: String, stowed: Device?) -> some View {
        Button {
            store.send(.binding(.set(\.selectedDeviceCode, code)))
        } label: {
            HStack(spacing: Space.s) {
                RCGlyphTile(Image.rcSymbol("device.\(stowed?.deviceType ?? "unknown")"))
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(stowed.map { DevicePresentation.displayName($0.deviceType) } ?? "Stowed Device")
                            .font(.rcBodyEmph)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                        Text(code)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                    if let stowed {
                        HStack(spacing: Space.s) {
                            StatusBadge(stowed.statusBase)
                            if let location = stowed.location {
                                Text(stowed.locationName ?? location)
                                    .font(.rcMonoSmall)
                                    .foregroundStyle(.rcTextTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.rcTextTertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: 0.5)
            )
    }
}

// MARK: - Cargo

/// The cargo manifest for a transport device (one with the `transport` feature):
/// each resource stack aboard with its quantity, plus a header reporting how full
/// the hold is (`cargo_used`/`cargo_capacity`). An empty hold still renders the
/// section — with an explicit "empty" note — so the capacity is discoverable and
/// the manifest is always present for a transport device.
private struct CargoSection: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text("CARGO")
                    .font(.rcSectionLabel).kerning(1)
                    .foregroundStyle(.rcTextTertiary)
                Spacer(minLength: 0)
                if device.cargoCapacity > 0 {
                    Text("\(Self.number(device.cargoUsed))/\(device.cargoCapacity) · \(device.cargoRemaining) free")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            if device.cargoItems.isEmpty {
                Text("Cargo hold empty.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(device.cargoItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(Color.rcSeparator) }
                        row(item)
                    }
                }
                .background(cardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One cargo row — the resource's display name and how many units are aboard.
    private func row(_ item: Device.CargoItem) -> some View {
        HStack(spacing: Space.s) {
            Text(DevicePresentation.displayName(item.resourceType))
                .font(.rcBodyEmph)
                .foregroundStyle(.rcTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(item.quantity) unit\(item.quantity == 1 ? "" : "s")")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: 0.5)
            )
    }

    /// Whole numbers stay whole (`80`), fractions keep one place (`1.5`).
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
    /// hydrated (see `.salvageSitesRequested`); depleted bodies drop out (relay
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
            Text("COMMANDS")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)

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
            Text("REQUIREMENT")
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
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
            Text("PRIORITY")
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
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
                Text("SALVAGE LOCATION")
                    .font(.rcSectionLabel)
                    .foregroundStyle(.rcTextTertiary)
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
