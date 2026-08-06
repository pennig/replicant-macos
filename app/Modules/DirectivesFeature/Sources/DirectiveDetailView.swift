//
//  DirectiveDetailView.swift
//  Replicould — Directives feature
//
//  The detail pane, branching on row kind. The two genuinely differ: a mission
//  has a target queue and a step timeline; a built-in AMI directive has a config
//  blob and the drones it's running. Built-in rows are editable right here —
//  in a three-pane layout this pane IS the device context, so sending the user
//  elsewhere to edit would re-introduce the asymmetry the unified surface exists
//  to remove.
//

import ComposableArchitecture
import DirectiveComposerFeature
import GameModels
import SwiftUI
import UI
import Utils

/// The built-in detail pane's config-flattening logic, deliberately kept out
/// of `DirectiveDetailView` itself. A `View` conformance infers `@MainActor`
/// isolation onto everything nested inside it (including otherwise-pure
/// static helpers), which both traps `swift test` on this SwiftUI-free logic
/// and forces every caller through the main actor for no reason. See the
/// "SwiftUI View statics trap in tests" memory note.
enum DirectiveConfigFlattening {
    /// Flatten a directive's config object into displayable label/value pairs.
    /// Nested objects — at any depth, e.g. the `delivery` route's `route.collect`,
    /// or deeper — render as dotted key paths rather than being dropped. `nil`
    /// only for a non-object top level; an empty object yields `[]`.
    static func pairs(_ config: JSONValue) -> [(key: String, value: String)]? {
        guard case .object = config else { return nil }
        return flatten(config, prefix: "")
    }

    /// The recursive step behind `pairs`. Keys are sorted at every level so
    /// the rendered order stays deterministic across renders regardless of
    /// dictionary iteration order.
    private static func flatten(_ value: JSONValue, prefix: String) -> [(key: String, value: String)] {
        guard case let .object(fields) = value else {
            return [(key: prefix, value: scalarString(value))]
        }
        return fields.keys.sorted().flatMap { key -> [(key: String, value: String)] in
            guard let child = fields[key] else { return [] }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            return flatten(child, prefix: path)
        }
    }

    /// Whether a flattened config value is a designation code — which must
    /// render in a mono token — rather than prose. Designations are upper-case
    /// alphanumerics with optional `-` groups (`SOL`, `SOL-3-1`, `TAU-4-SAL-2`)
    /// and never contain spaces. Config *keys* can't drive this: each directive
    /// names its target differently (`location`, `target`, `destination`), so
    /// the value's own shape is the stable signal.
    ///
    /// Known over-match, deliberately accepted: an all-caps resource name like
    /// `IRON` also renders mono. It reads as a code either way.
    static func isDesignation(_ value: String) -> Bool {
        guard value.count >= 3, !value.contains(" ") else { return false }
        return value.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "-" }
    }

    /// Render a scalar JSON value for display. Arrays join; anything else falls
    /// back to a compact description.
    static func scalarString(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        if let bool = value.boolValue { return bool ? "Yes" : "No" }
        if let number = value.numberValue {
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        if let array = value.arrayValue {
            return array.compactMap(\.stringValue).joined(separator: ", ")
        }
        return "—"
    }
}

public struct DirectiveDetailView: View {
    @Bindable var store: StoreOf<DirectivesFeature>

    public init(store: StoreOf<DirectivesFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            // The brain is checked FIRST and off the same selection: its
            // reserved id resolves to no row, so leaving it to the `nil` branch
            // would render "No Selection" over a deliberate one.
            if store.isBrainSelected, let why = store.brainWhy {
                BrainWhyDetailView(why: why)
            } else {
                switch store.selectedRow {
                case let .builtIn(builtIn):
                    builtInDetail(builtIn)
                case let .custom(directive, _):
                    customDetail(directive)
                case nil:
                    RCContentUnavailableView("No Selection", systemImage: "square.dashed")
                }
            }
        }
        // Feature-tier sheet: @Presents + scope, never .sheet(isPresented:).
        .sheet(item: $store.scope(state: \.composer, action: \.composer)) { composerStore in
            DirectiveComposerSheet(store: composerStore)
        }
    }

    // MARK: Built-in

    @ViewBuilder
    private func builtInDetail(_ builtIn: BuiltInDirective) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header(
                    title: BlueprintPresentation.displayName(builtIn.directive),
                    subtitle: builtIn.deviceCode,
                    caption: BlueprintPresentation.displayName(builtIn.deviceType)
                )

                if let config = builtIn.config,
                   let pairs = DirectiveConfigFlattening.pairs(config), !pairs.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RCSectionHeader("Configuration")
                        ForEach(pairs, id: \.key) { pair in
                            detailRow(pair.key, pair.value)
                        }
                    }
                }

                if !builtIn.controlledDevices.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RCSectionHeader("Controlled Devices")
                        ForEach(builtIn.controlledDevices) { controlled in
                            controlledRow(controlled)
                        }
                    }
                }

                // The completion history §2 promised a built-in row when it
                // gave `DirectiveLogEntry` its optional device key.
                timelineSection(title: "History")

                if let owner = builtIn.drivenBy {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: IconSize.s))
                            .foregroundStyle(.rcTextTertiary)
                        Text("Driven by \(owner.kindTitle) — Reconfigure and Clear are disabled while the mission is running.")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }

                HStack(spacing: Space.s) {
                    Button("Reconfigure") { store.send(.reconfigureTapped) }
                        .buttonStyle(RCButtonStyle(.primary))
                    Button("Clear") { store.send(.clearTapped) }
                        .buttonStyle(RCButtonStyle(.secondary))
                    Spacer()
                }
                .disabled(builtIn.drivenBy != nil)
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(BlueprintPresentation.displayName(builtIn.directive))
    }

    /// One controlled drone: its code (mono — it's a designation), type, and
    /// live status.
    private func controlledRow(_ controlled: Device.ControlledDevice) -> some View {
        HStack(spacing: Space.s) {
            Text(controlled.deviceCode)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextPrimary)
            Text(BlueprintPresentation.displayName(controlled.deviceType))
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
            Spacer(minLength: 0)
            if let status = controlled.status {
                StatusBadge(status)
            }
        }
        .padding(.vertical, Space.xxs)
    }

    // MARK: Custom

    /// Missions can't exist until Stage 3 lands the engine, but the pane is
    /// written now so the branch is real rather than a fatalError waiting to
    /// happen if a row is ever hand-inserted.
    @ViewBuilder
    private func customDetail(_ directive: Directive) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.s) {
                    header(
                        title: directive.kind.title,
                        subtitle: directive.deviceCode,
                        caption: directive.status.displayName
                    )
                    Spacer(minLength: 0)
                    holdControl(directive)
                }

                if directive.status == .needsAttention, let reason = directive.attentionReason {
                    DirectiveStallPanel(
                        reason: reason,
                        retry: { store.send(.retryTapped) },
                        skip: { store.send(.skipTargetTapped) },
                        cancel: { store.send(.cancelRunTapped) }
                    )
                }

                if directive.status == .running {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        RCSectionHeader("Now")
                        HStack(spacing: Space.xs) {
                            ProgressView().controlSize(.small)
                            Text(directive.step)
                                .font(.rcBodyEmph)
                                .foregroundStyle(.rcTextPrimary)
                            Text("·").foregroundStyle(.rcTextTertiary)
                            // Ticks on its own — no timer, no formatter.
                            Text(directive.stepStartedAt, style: .relative)
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextSecondary)
                            Spacer(minLength: 0)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    RCSectionHeader("Targets")
                    // Keyed by position, not element: `targets` is a revisit
                    // queue and the same system designation can legitimately
                    // appear twice, which would collide as a SwiftUI id.
                    ForEach(Array(directive.targets.enumerated()), id: \.offset) { index, target in
                        HStack(spacing: Space.s) {
                            // `hasDelivered(targetAt:)`, never a bare
                            // `targetIndex` comparison: the cursor is not a
                            // completion count, and a Relay Run finishes
                            // without ever moving it.
                            let delivered = directive.hasDelivered(targetAt: index)
                            Image(systemName: delivered ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(delivered ? .rcAccent : .rcTextTertiary)
                            Text(target)
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }

                timelineSection(title: "Timeline")
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(directive.kind.title)
    }

    /// The timeline, shared by both panes: a mission's step history and a
    /// built-in directive's completion history come from one query keyed by
    /// whichever id the selected row carries.
    @ViewBuilder
    private func timelineSection(title: String) -> some View {
        let rows = DirectiveLogCollapsing.collapse(store.timeline.entries).prefix(DirectiveTimeline.entryLimit)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                RCSectionHeader(title)
                ForEach(rows) { row in
                    DirectiveTimelineRow(entry: row.entry, count: row.count)
                }
            }
        }
    }

    /// Pause / Resume, shown only where it applies. A finished run offers
    /// neither — there is nothing left to hold.
    @ViewBuilder
    private func holdControl(_ directive: Directive) -> some View {
        switch directive.status {
        case .running:
            Button("Pause") { store.send(.pauseTapped) }
                .buttonStyle(RCButtonStyle(.secondary))
        case .paused:
            Button("Resume") { store.send(.resumeTapped) }
                .buttonStyle(RCButtonStyle(.primary))
        case .needsAttention, .completed, .cancelled:
            EmptyView()
        }
    }

    // MARK: Shared chrome

    private func header(title: String, subtitle: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            HStack(spacing: Space.xs) {
                Text(subtitle)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
                Text("·").foregroundStyle(.rcTextTertiary)
                Text(caption)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Text(label)
                .font(.rcFieldLabel)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(DirectiveConfigFlattening.isDesignation(value) ? .rcMonoSmall : .rcCaption)
                .foregroundStyle(.rcTextPrimary)
            Spacer(minLength: 0)
        }
    }
}
