//
//  DirectiveComposerSheet.swift
//  Replicould — Directive composer feature
//
//  The `set_directive` composer sheet: a directive picker plus the selected
//  directive's configuration form (survey scopes, the salvage-body picker fed
//  by the local locations catalog, the transport routes with their requirement
//  and priority editors). Mirrors the inspector's other sheets' chrome
//  (header · divider · content · trailing footer) and drives a presented
//  `DirectiveComposer` store — confirm and cancel are reducer intents, so the
//  view stays a pure renderer.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI
import UniverseModels

public struct DirectiveComposerSheet: View {
    @Bindable var store: StoreOf<DirectiveComposer>

    public init(store: StoreOf<DirectiveComposer>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            Divider().overlay(Color.rcSeparator)
            directivePicker
            configuration(store.directive)
            footer
        }
        .padding(Space.xl)
        .frame(width: 460)
        .background(Color.rcContentBackground)
        .task { store.send(.task) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: IconSize.l, weight: .medium))
                .foregroundStyle(.rcAccent)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Set Directive")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                Text(store.deviceCode)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Directive picker

    private var directivePicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Directive".uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            RCValueSelect(
                "Directive",
                options: store.availableDirectives.map {
                    (label: BlueprintPresentation.displayName($0), value: $0)
                },
                selection: $store.directive
            )
        }
    }

    // MARK: Per-directive configuration

    /// Configuration controls for a configurable directive. Empty for
    /// directives that carry no configuration (belt_search, patrol, …).
    @ViewBuilder
    private func configuration(_ directive: String) -> some View {
        switch directive {
        case "survey_system":
            VStack(alignment: .leading, spacing: Space.s) {
                configField("Planets", selection: $store.planetsScope)
                configField("Moons", selection: $store.moonsScope)
                recallToggle
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

    /// The shared "Recall when complete" switch (survey + salvage).
    private var recallToggle: some View {
        Toggle(isOn: $store.recall) {
            Text("Recall when complete")
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
        }
        .toggleStyle(.switch)
        .tint(.rcAccent)
    }

    /// A labeled all/none scope dropdown for a survey config field.
    private func configField(_ label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label.uppercased())
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
            RCValueSelect(
                label,
                options: [DirectiveComposer.SurveyScope.all, DirectiveComposer.SurveyScope.none],
                selection: selection
            )
        }
    }

    /// The `gather_salvage` config: a required salvage-body picker (sourced
    /// from the controller's system in the local catalog) plus the recall
    /// toggle. The directive targets a body — its drones work every salvage
    /// site there — so the picker offers bodies. The backend rejects the
    /// directive without a `location`, so confirm stays disabled until a body
    /// is chosen.
    @ViewBuilder
    private var salvageConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                RCSectionHeader("Salvage Location")
                if store.salvageBodies.isEmpty {
                    Text("No known salvage in this system yet. Scan its bodies in Locations to reveal them.")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                } else {
                    RCValueSelect(
                        "Salvage Location",
                        options: store.salvageBodies.map {
                            (label: salvageBodyLabel($0), value: $0.designation)
                        },
                        selection: $store.salvageLocation
                    )
                }
            }
            recallToggle
        }
        .padding(.top, Space.xs)
        // Auto-select the first body once the catalog hydrates, unless one is
        // already chosen (kept selection or a seeded running directive).
        .onChange(of: store.salvageBodies.map(\.id)) { _, _ in
            if store.salvageLocation.isEmpty {
                store.salvageLocation = store.salvageBodies.first?.designation ?? ""
            }
        }
    }

    /// A salvage body's dropdown label — its name/designation, annotated with
    /// the site count when it holds more than one (the drones work them all).
    private func salvageBodyLabel(_ body: SalvageBody) -> String {
        body.siteCount > 1 ? "\(body.displayName) · \(body.siteCount) sites" : body.displayName
    }

    /// The `delivery` config: a one-shot collect → deliver route plus the
    /// per-resource target that defines when the run is complete. The backend
    /// rejects the directive without a requirement, so confirm stays disabled
    /// until both endpoints and at least one amount are set.
    @ViewBuilder
    private var deliveryConfiguration: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCField("Collect From", text: $store.collectLocation, placeholder: "ATIANFU-BELT-1", mono: true)
            RCField("Deliver To", text: $store.deliverLocation, placeholder: "ALPHERATOZ-8-L4", mono: true)
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
                text: $store.collectLocation,
                placeholder: interstellar ? "TARAZEDAR-BELT-1" : "ATIANFU-BELT-1",
                hint: interstellar ? "source system" : nil,
                mono: true
            )
            RCField(
                "Deliver To",
                text: $store.deliverLocation,
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
            RCField("Deliver To", text: $store.deliverLocation, placeholder: "ALPHERATOZ-8-L4", mono: true)
            priorityEditor
        }
        .padding(.top, Space.xs)
    }

    // MARK: Requirement editor (delivery)

    /// The `delivery` requirement editor: one numeric field per resource type.
    /// Only resources with a positive amount are sent; together they define
    /// the quota that completes the one-shot run.
    @ViewBuilder
    private var requirementEditor: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Requirement")
            Text("Amounts to deliver before the run completes.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
            VStack(spacing: 0) {
                ForEach(Array(MiningResource.all.enumerated()), id: \.element) { index, resource in
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
    /// field clears the entry rather than leaving a stale amount. Writes go
    /// through the bindable store, so the reducer owns the map.
    private func requirementBinding(_ resource: String) -> Binding<String> {
        Binding(
            get: { store.requirement[resource] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                var updated = store.requirement
                if trimmed.isEmpty { updated[resource] = nil } else { updated[resource] = trimmed }
                store.requirement = updated
            }
        )
    }

    // MARK: Priority editor (shuttle / ferry / consolidate)

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
                ForEach(MiningResource.all, id: \.self) { resource in
                    priorityChip(resource)
                }
            }
        }
    }

    /// A single priority chip: accent-filled with its rank number when
    /// selected, a bordered surface otherwise.
    private func priorityChip(_ resource: String) -> some View {
        let rank = store.priorityResources.firstIndex(of: resource)
        let selected = rank != nil
        return Button {
            store.send(.priorityToggled(resource))
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.s) {
            Spacer()
            Button("Cancel") { store.send(.cancelTapped) }
                .buttonStyle(RCButtonStyle(.secondary))
            Button("Set Directive") { store.send(.confirmTapped) }
                .buttonStyle(RCButtonStyle(.primary))
                .disabled(!store.isConfirmable)
        }
    }
}
