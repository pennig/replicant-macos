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

public struct DirectiveDetailView: View {
    @Bindable var store: StoreOf<DirectivesFeature>

    public init(store: StoreOf<DirectivesFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            switch store.selectedRow {
            case let .builtIn(builtIn):
                builtInDetail(builtIn)
            case let .custom(directive):
                customDetail(directive)
            case nil:
                RCContentUnavailableView("No Selection", systemImage: "square.dashed")
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

                if let config = builtIn.config, let pairs = configPairs(config), !pairs.isEmpty {
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

                HStack(spacing: Space.s) {
                    Button("Reconfigure") { store.send(.reconfigureTapped) }
                        .buttonStyle(RCButtonStyle(.primary))
                    Button("Clear") { store.send(.clearTapped) }
                        .buttonStyle(RCButtonStyle(.secondary))
                    Spacer()
                }
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

    /// Flatten a directive's config object into displayable label/value pairs.
    /// Nested objects (the `delivery` route) render as `route.collect` style
    /// keys rather than being dropped.
    private func configPairs(_ config: JSONValue) -> [(key: String, value: String)]? {
        guard case let .object(fields) = config else { return nil }
        return fields.keys.sorted().flatMap { key -> [(key: String, value: String)] in
            guard let value = fields[key] else { return [] }
            if case let .object(nested) = value {
                return nested.keys.sorted().compactMap { inner in
                    nested[inner].map { (key: "\(key).\(inner)", value: scalarString($0)) }
                }
            }
            return [(key: key, value: scalarString(value))]
        }
    }

    /// Render a scalar JSON value for display. Arrays join; anything else falls
    /// back to a compact description.
    private func scalarString(_ value: JSONValue) -> String {
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

    // MARK: Custom

    /// Missions can't exist until Stage 3 lands the engine, but the pane is
    /// written now so the branch is real rather than a fatalError waiting to
    /// happen if a row is ever hand-inserted.
    @ViewBuilder
    private func customDetail(_ directive: Directive) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header(
                    title: directive.kind.title,
                    subtitle: directive.deviceCode,
                    caption: directive.status.rawValue
                )
                VStack(alignment: .leading, spacing: Space.xs) {
                    RCSectionHeader("Targets")
                    ForEach(Array(directive.targets.enumerated()), id: \.element) { index, target in
                        HStack(spacing: Space.s) {
                            Image(systemName: index < directive.targetIndex
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(index < directive.targetIndex ? .rcAccent : .rcTextTertiary)
                            Text(target)
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(directive.kind.title)
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
                .font(.rcCaption)
                .foregroundStyle(.rcTextPrimary)
            Spacer(minLength: 0)
        }
    }
}
