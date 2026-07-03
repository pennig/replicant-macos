//
//  SidebarChrome.swift
//  Replicould — UI
//
//  The sidebar's top and bottom furniture: the ACTIVE REPLICANT header (host
//  switcher + live travel/printing progress + at-a-glance stats) and the LOGGED
//  IN account footer (identity + total experience + roster size). Both are pure
//  design-system views over plain value inputs, so the app layer feeds them real
//  data and they stay previewable in isolation. The header reuses
//  `RCEntitySwitcher` for the picker and the same on-device progress math the
//  operation bars use, so a running trip or print interpolates with zero network.
//

import SwiftUI

// MARK: - Active replicant progress

/// A single running activity for the active replicant, distilled from its
/// hosting/working device so the header can draw a live bar. `startedAt` /
/// `completesAt` drive the fill entirely on device (like `OperationProgressView`).
public struct RCReplicantProgress: Equatable, Sendable {
    /// The thing under way — a travel destination, the device type being printed, etc.
    public var label: String
    /// Optional leading glyph (e.g. an arrow for travel, a printer for printing).
    public var symbol: String?
    public var startedAt: Date
    public var completesAt: Date
    /// Status tone for the fill + dot, mapped through `DeviceStatus.tone(for:)`.
    public var tint: Color

    public init(label: String, symbol: String? = nil, startedAt: Date, completesAt: Date, tint: Color) {
        self.label = label
        self.symbol = symbol
        self.startedAt = startedAt
        self.completesAt = completesAt
        self.tint = tint
    }
}

// MARK: - Active replicant header

/// The ACTIVE REPLICANT box: a titled host switcher, a live progress row (travel
/// or printing) or the current-location line when idle, and an XP · devices ·
/// "Show in Replicants" stats footer. All inputs are plain values; the app layer
/// derives them from the roster + fleet.
public struct RCActiveReplicantHeader: View {
    let replicants: [RCReplicant]
    @Binding var selection: RCReplicant
    /// Where the active replicant currently is (shown when nothing is under way).
    let location: String?
    let experiencePoints: Int
    let deviceCount: Int
    /// A running trip / print, if any — replaces the static location line.
    let progress: RCReplicantProgress?
    /// The replicant's public plan (the editable mission line), or nil/empty when
    /// none is set. Shown with an edit affordance when `onEditPlan` is provided.
    let plan: String?
    var onShowInReplicants: (() -> Void)?
    var onCommission: (() -> Void)?
    /// Called with the new plan text when the user saves an edit. When nil the
    /// plan line is read-only (and hidden if there's no plan to show).
    var onEditPlan: ((String) -> Void)?

    public init(
        replicants: [RCReplicant],
        selection: Binding<RCReplicant>,
        location: String?,
        experiencePoints: Int,
        deviceCount: Int,
        progress: RCReplicantProgress? = nil,
        plan: String? = nil,
        onShowInReplicants: (() -> Void)? = nil,
        onCommission: (() -> Void)? = nil,
        onEditPlan: ((String) -> Void)? = nil
    ) {
        self.replicants = replicants
        self._selection = selection
        self.location = location
        self.experiencePoints = experiencePoints
        self.deviceCount = deviceCount
        self.progress = progress
        self.plan = plan
        self.onShowInReplicants = onShowInReplicants
        self.onCommission = onCommission
        self.onEditPlan = onEditPlan
    }

    @State private var isEditingPlan = false
    @State private var planDraft = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("ACTIVE REPLICANT")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)

            RCEntitySwitcher(replicants, selection: $selection, onCommission: onCommission)
                .padding(.horizontal, -Space.xs) // kick out the sides for visual balance (round corners make it appear more narrow than it actually is)

            if let progress {
                // Reset the fill's finish-line latch when the operation changes.
                RCReplicantProgressView(progress: progress).id(progress.startedAt)
            } else if let location, !location.isEmpty {
                staticLocation(location)
            }

            statsRow

            if onEditPlan != nil || !(plan ?? "").isEmpty {
                planRow
            }
        }
    }

    /// The public plan — the replicant's current mission — with an inline edit
    /// affordance that opens a small composer popover.
    private var planRow: some View {
        let hasPlan = !(plan ?? "").isEmpty
        return HStack(alignment: .top, spacing: Space.s) {
            Text(hasPlan ? plan! : "Set a plan…")
                .font(.rcBody)
                .foregroundStyle(hasPlan ? .rcTextSecondary : .rcTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if onEditPlan != nil {
                Button {
                    planDraft = plan ?? ""
                    isEditingPlan = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.rcTextTertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isEditingPlan, arrowEdge: .bottom) {
                    planEditor
                }
            }
        }
        .padding(.top, Space.xs)
    }

    private var planEditor: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("CURRENT PLAN")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)
            TextEditor(text: $planDraft)
                .font(.rcBody)
                .scrollContentBackground(.hidden)
                .frame(width: 300, height: 96)
                .padding(Space.s)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(.rcSurfaceRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(.rcSeparator, lineWidth: 1)
                        )
                )
                // The backend caps the plan at 500 characters.
                .onChange(of: planDraft) { _, new in
                    if new.count > 500 { planDraft = String(new.prefix(500)) }
                }
            HStack {
                Text("\(planDraft.count)/500")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                Spacer()
                Button("Cancel") { isEditingPlan = false }
                    .buttonStyle(RCButtonStyle(.secondary))
                Button("Save") {
                    onEditPlan?(planDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                    isEditingPlan = false
                }
                .buttonStyle(RCButtonStyle(.primary))
            }
        }
        .padding(Space.m)
        .frame(width: 332)
        .background(.rcContentBackground)
    }

    /// The at-rest location line: a muted dot + where the replicant sits now.
    private func staticLocation(_ location: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.rcTextTertiary).frame(width: 6, height: 6)
            Text(location)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// XP · devices, then the "Show in Replicants" jump. Stacked (not inline) so
    /// it never crowds the narrow sidebar.
    private var statsRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: 6) {
                stat(value: experiencePoints.formatted(), unit: "XP")
                Text("·").foregroundStyle(.rcTextTertiary)
                stat(value: "\(deviceCount)", unit: deviceCount == 1 ? "device" : "devices")
                Spacer(minLength: 0)
            }
            if let onShowInReplicants {
                Button("Show in Replicants  ↗", action: onShowInReplicants)
                    .buttonStyle(RCButtonStyle(.text))
            }
        }
    }

    private func stat(value: String, unit: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.rcTextPrimary)
            Text(unit)
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
        }
    }
}

/// The header's live progress row: a thin fill bar + a "<glyph> destination …
/// ETA" caption, interpolated on device from `startedAt`/`completesAt` and
/// latched at the finish line so a slipped ETA never rewinds it.
struct RCReplicantProgressView: View {
    let progress: RCReplicantProgress
    @State private var reachedEnd = false

    var body: some View {
        // Anchor the 1s tick phase on `completesAt`, not `startedAt`: the readout
        // is a countdown to arrival, so its integer-second boundaries land on
        // `completesAt − n`. Phasing on `startedAt` puts each tick a fractional
        // beat (the trip's sub-second remainder, ~0.5s on average) *after* the
        // real boundary, so the readout lagged by that much.
        TimelineView(.periodic(from: progress.completesAt, by: 1)) { context in
            let pending = reachedEnd || context.date >= progress.completesAt
            let fraction = pending
                ? 1
                : ProgressMath.fraction(now: context.date, start: progress.startedAt, end: progress.completesAt)
            VStack(alignment: .leading, spacing: 6) {
                bar(fraction: fraction)
                HStack(spacing: 6) {
                    Circle().fill(progress.tint).frame(width: 6, height: 6)
                        .shadow(color: progress.tint.opacity(0.6), radius: 3)
                    if let symbol = progress.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.rcTextTertiary)
                    }
                    Text(progress.label)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(pending ? "Arriving…" : RCDuration.compact(seconds: progress.completesAt.timeIntervalSince(context.date)))
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                        .monospacedDigit()
                }
            }
            .onChange(of: pending, initial: true) { _, isPending in
                if isPending { reachedEnd = true }
            }
        }
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.rcSeparator)
                Capsule().fill(progress.tint)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Account footer

/// The LOGGED IN box: account identity on the left, total experience + roster
/// size on the right, the whole row a button that opens the Account sheet.
public struct RCAccountFooter: View {
    let name: String
    let email: String
    let experiencePoints: Int
    let replicantCount: Int
    let action: () -> Void

    @State private var hover = false

    public init(
        name: String,
        email: String,
        experiencePoints: Int,
        replicantCount: Int,
        action: @escaping () -> Void
    ) {
        self.name = name
        self.email = email
        self.experiencePoints = experiencePoints
        self.replicantCount = replicantCount
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.rcTextTertiary)
                    Text("LOGGED IN")
                        .font(.rcSectionLabel).kerning(1)
                        .foregroundStyle(.rcTextTertiary)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center, spacing: Space.s) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name.isEmpty ? "—" : name)
                            .font(.rcBodyEmph)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                        Text(email)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: Space.s)
                    VStack(alignment: .trailing, spacing: 1) {
                        stat(value: RCDuration.compact(count: experiencePoints), unit: "XP")
                        stat(value: "\(replicantCount)", unit: "repl")
                    }
                    Image(systemName: "chevron.right")
                        .font(.rcCaption.weight(.semibold))
                        .foregroundStyle(.rcTextTertiary)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.m)
            .background(Color.rcTextPrimary.opacity(hover ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private func stat(value: String, unit: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.rcAccent)
            Text(unit)
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
        }
    }
}

// MARK: - Compact number / duration formatting

/// Small formatting helpers shared by the sidebar chrome: compact large counts
/// (`128400` → `128.4k`) and compact remaining durations (`8040s` → `2h 14m`).
enum RCDuration {
    /// A compact magnitude label for a large count, e.g. `128.4k` / `2.1M`.
    static func compact(count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fk", Double(count) / 1_000)
        default:
            return "\(count)"
        }
    }

    /// A compact remaining-time label from a seconds interval: `2h 14m`, `14m 3s`,
    /// or `9s`. Coarsens as the horizon grows so the sidebar stays legible.
    static func compact(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}

// MARK: - Preview

#Preview("Sidebar chrome") {
    struct Harness: View {
        @State private var active = RCReplicant(id: "B58FCC78", name: "Sylphrena", host: .vessel)
        private let reps = [
            RCReplicant(id: "B58FCC78", name: "Sylphrena", host: .vessel),
            RCReplicant(id: "A21D90F3", name: "Pattern", host: .matrix),
            RCReplicant(id: "C77E1A2B", name: "Testament", host: .hub),
        ]
        var body: some View {
            VStack(spacing: 0) {
                RCActiveReplicantHeader(
                    replicants: reps,
                    selection: $active,
                    location: "TARAZEDAR-BELT-1",
                    experiencePoints: 12_840,
                    deviceCount: 10,
                    progress: RCReplicantProgress(
                        label: "TARAZEDAR-BELT-1",
                        symbol: "arrow.right",
                        startedAt: Date().addingTimeInterval(-3_600),
                        completesAt: Date().addingTimeInterval(8_040),
                        tint: .rcStatusTransit
                    ),
                    plan: "Seed the Chamakuy belt with self-sustaining infrastructure.",
                    onShowInReplicants: {},
                    onCommission: {},
                    onEditPlan: { _ in }
                )
                Divider()
                Spacer()
                Divider()
                RCAccountFooter(
                    name: "K. Pennig",
                    email: "kell@pennig.name",
                    experiencePoints: 128_400,
                    replicantCount: 5,
                    action: {}
                )
            }
            .frame(width: 240, height: 460)
            .background(.rcSidebarBackground)
        }
    }
    return Harness()
}
