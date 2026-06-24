//
//  StarMapView.swift
//  StarMapFeature
//
//  The Galaxy Explorer content pane: a SceneKit map under a SwiftUI glass HUD.
//  The map is dark-only (spec §2), so the HUD forces the dark appearance and
//  draws entirely from the UI design tokens.
//

import ComposableArchitecture
import SQLiteData
import SwiftUI
import UI

public struct StarMapView: View {
    @Bindable var store: StoreOf<StarMapFeature>
    /// The charted galaxy, observed straight from the `Star` table — new rows
    /// (from a survey) flow into the scene automatically. Sorted by distance so
    /// the home system (0) sorts first.
    @FetchAll(Star.order(by: \.createdAt)) private var stars

    public init(store: StoreOf<StarMapFeature>) {
        self.store = store
    }

    private var chartedStarCount: Int { stars.count }

    /// The selected/focused star as a presentation system for the HUD.
    private func system(forID id: String?) -> GalaxySystem? {
        guard let id, let star = stars.first(where: { $0.id == id }) else { return nil }
        return GalaxySystem(surveyed: star.item, isCurrentLocation: star.designation == "ATIANFU")
    }
    private var selectedSystem: GalaxySystem? { system(forID: store.selectedSystemID) }
    private var focusedSystem: GalaxySystem? {
        guard case let .system(id) = store.focus else { return nil }
        return system(forID: id)
    }

    public var body: some View {
        ZStack {
            StarMapSceneView(
                store: store,
                focus: store.focus,
                resetToken: store.cameraResetToken,
                stars: stars,
                flashNew: store.bootPhase == .rebuilding,
                interactive: store.bootPhase == .idle
            )
            .ignoresSafeArea()

            switch store.focus {
            case .galaxy:
                galaxyHUD.transition(.opacity)
            case .system:
                if let system = focusedSystem {
                    SystemHUD(system: system, isTransitioning: store.isTransitioning) {
                        store.send(.zoomOutRequested)
                    }
                    .transition(.opacity)
                }
            }

            // The themed first-run "database rebuild" sequence, over everything.
            if store.bootPhase != .idle {
                BootRebuildOverlay(store: store)
                    .transition(.opacity)
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.6), value: store.focus)
        .animation(.easeInOut(duration: 0.22), value: store.selectedSystemID)
        .animation(.easeInOut(duration: 0.4), value: store.bootPhase)
        .navigationTitle(navigationTitle)
        .task { store.send(.task) }
    }

    private var navigationTitle: String {
        focusedSystem.map { "Galaxy · \($0.name)" } ?? "Galaxy"
    }

    // MARK: - Galaxy HUD

    private var galaxyHUD: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                Spacer()
                HStack(alignment: .bottom) {
                    if let system = selectedSystem {
                        SystemDossier(
                            system: system,
                            canDrill: system.star.explored && !store.isTransitioning,
                            onDrill: { store.send(.drillInRequested(system.id)) },
                            onClose: { store.send(.systemTapped(nil)) }
                        )
                        .frame(maxWidth: 280)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer()
                    controls
                }
            }
            .padding(Space.l)

            // Layer rail, pinned top-trailing.
            VStack {
                HStack {
                    Spacer()
                    LayerRail(active: store.activeLayers) { layer in
                        store.send(.layerToggled(layer))
                    }
                }
                Spacer()
            }
            .padding(Space.l)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Galaxy Explorer")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            Text(chartedStarCount > 0 ? "\(chartedStarCount.formatted()) charted stars" : "Uncharted")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .hudGlass()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            surveyControl

            Divider().overlay(.rcSeparator)

            Toggle(isOn: Binding(
                get: { store.autoRotate },
                set: { _ in store.send(.autoRotateToggled) }
            )) {
                Text("Auto-rotate").font(.rcCaption).foregroundStyle(.rcTextSecondary)
            }
            .toggleStyle(.switch)
            .tint(.rcAccent)

            Button {
                store.send(.recenterTapped)
            } label: {
                Label("Recenter", systemImage: "scope")
                    .font(.rcCaption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.rcTextSecondary)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(width: 184, alignment: .leading)
        .hudGlass()
    }

    @ViewBuilder private var surveyControl: some View {
        if store.isSurveying {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Surveying…").font(.rcCaption).foregroundStyle(.rcTextSecondary)
                }
                if let total = store.surveyTotalPages {
                    ProgressView(value: Double(store.surveyPagesDone), total: Double(max(total, 1)))
                        .tint(.rcAccent)
                    Text("Page \(store.surveyPagesDone) / \(total) · \(store.surveyStarCount.formatted()) stars")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    store.send(.surveyButtonTapped)
                } label: {
                    Label("Survey nearby stars", systemImage: "dot.radiowaves.left.and.right")
                        .font(.rcCaption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.rcAccent)

                if let error = store.surveyError {
                    Text(error)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Layer rail

private struct LayerRail: View {
    let active: Set<InfoLayer>
    let onToggle: (InfoLayer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Layers")
                .font(.rcSectionLabel)
                .foregroundStyle(.rcTextTertiary)
                .textCase(.uppercase)
                .padding(.bottom, 2)
            ForEach(InfoLayer.allCases) { layer in
                LayerToggle(layer: layer, isOn: active.contains(layer)) {
                    onToggle(layer)
                }
            }
        }
        .padding(Space.m)
        .frame(width: 196, alignment: .leading)
        .hudGlass()
    }
}

private struct LayerToggle: View {
    let layer: InfoLayer
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Circle()
                    .fill(layer.legendColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: layer.legendColor.opacity(0.6), radius: isOn ? 3 : 0)
                    .opacity(isOn ? 1 : 0.35)
                Text(layer.label)
                    .font(.rcBody)
                    .foregroundStyle(isOn ? .rcTextPrimary : .rcTextTertiary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? layer.legendColor : .rcTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System dossier

private struct SystemDossier: View {
    let system: GalaxySystem
    let canDrill: Bool
    let onDrill: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(system.name)
                        .font(.rcHeadline)
                        .foregroundStyle(.rcTextPrimary)
                    Text("\(system.id) · \(system.spectralType)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.rcTextTertiary)
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(.rcSeparator)

            HStack(spacing: Space.s) {
                Image(systemName: reconSymbol).font(.system(size: 11))
                Text(system.recon.label)
                if let presence = system.presence {
                    Text("·").foregroundStyle(.rcTextTertiary)
                    Text(presence.label)
                        .foregroundStyle(presence == .mine ? .rcAccent : .rcNPC)
                }
            }
            .font(.rcCaption)
            .foregroundStyle(.rcTextSecondary)

            HStack(spacing: Space.l) {
                stat("Devices", "\(system.deviceCount)")
                stat("Vessels", "\(system.vesselCount)")
                stat("Planets", "\(system.star.estimatedPlanets)")
            }

            HStack(spacing: Space.l) {
                readout("Resource", value: system.resourceRichness, color: .rcStatusWaiting)
                if let life = system.lifeTier {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Life").font(.rcCaption).foregroundStyle(.rcTextTertiary)
                        Text(life.label).font(.rcBodyEmph).foregroundStyle(.rcStatusReady)
                    }
                }
            }

            Text("\(distanceText) · \(system.star.estimatedPlanets) est. planets")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)

            if system.star.explored {
                Button(action: onDrill) {
                    Label("View system", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
                        .font(.rcCaption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canDrill ? .rcAccent : .rcTextTertiary)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .fill(.rcAccent.opacity(canDrill ? 0.14 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(.rcAccent.opacity(canDrill ? 0.4 : 0.12), lineWidth: 0.5)
                )
                .disabled(!canDrill)
                .padding(.top, 2)
            }
        }
        .padding(Space.m)
        .hudGlass()
    }

    private var reconSymbol: String {
        switch system.recon {
        case .scanned: "circle.fill"
        case .visited: "circle.lefthalf.filled"
        case .aware:   "circle"
        }
    }

    private var distanceText: String {
        system.isCurrentLocation ? "Current Location" : String(format: "%.1f ly", 3.2)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.rcCaption).foregroundStyle(.rcTextTertiary)
            Text(value).font(.rcBodyEmph).foregroundStyle(.rcTextPrimary)
        }
    }

    private func readout(_ label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.rcCaption).foregroundStyle(.rcTextTertiary)
            ZStack(alignment: .leading) {
                Capsule().fill(.rcSurfaceRaised).frame(width: 64, height: 5)
                Capsule().fill(color).frame(width: 64 * value, height: 5)
            }
        }
    }
}

// MARK: - System HUD

private struct SystemHUD: View {
    let system: GalaxySystem
    let isTransitioning: Bool
    let onBack: () -> Void

    private var model: SystemModel { ChamakuyData.model(for: system) }

    var body: some View {
        ZStack {
            // Top-leading: back control + star dossier.
            VStack(alignment: .leading, spacing: Space.m) {
                starCard
                Spacer()
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Bottom-trailing: tracked bodies & devices.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    bodiesCard
                }
            }
            .padding(Space.l)
        }
    }

    private var starCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button(action: onBack) {
                Label("Back to Galaxy", systemImage: "arrow.up.left")
                    .font(.rcCaption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.rcAccent)
            .disabled(isTransitioning)

            Divider().overlay(.rcSeparator)

            Text(model.star.name)
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            Text("\(model.star.designation) · \(model.star.spectralType) · \(model.star.temperatureK) K")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)

            HStack(spacing: Space.l) {
                fact("Mass", String(format: "%.2f M☉", model.star.massSolar))
                fact("Lum", String(format: "%.2f L☉", model.star.luminositySolar))
            }
            HStack(spacing: Space.l) {
                fact("Habitable zone", String(format: "%.2f–%.2f AU", model.star.habitableZone.innerAu, model.star.habitableZone.outerAu))
            }
            HStack(spacing: Space.l) {
                fact("Planets", "\(model.planets.count)")
                fact("Belt", model.belt.detail.density)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: 260, alignment: .leading)
        .hudGlass()
    }

    private var bodiesCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Bodies")
                .font(.rcSectionLabel)
                .textCase(.uppercase)
                .foregroundStyle(.rcTextTertiary)
            ForEach(model.planets) { planet in
                HStack(spacing: Space.s) {
                    Circle()
                        .fill(planet.summary.inHabitableZone ? .rcStatusReady : .rcTextSecondary)
                        .frame(width: 7, height: 7)
                    Text("\(planet.summary.designation) · \(planet.summary.name)")
                        .font(.rcBody)
                        .foregroundStyle(.rcTextPrimary)
                    Spacer()
                    Text(planet.summary.type)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
            Divider().overlay(.rcSeparator)
            HStack(spacing: Space.l) {
                fact("Devices", "\(model.devices.count)")
                fact("Vessels", "\(model.vessels.count)")
                fact("Lagrange", "\(model.lagrange.count)")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: 240, alignment: .leading)
        .hudGlass()
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.rcCaption).foregroundStyle(.rcTextTertiary)
            Text(value).font(.rcBodyEmph).foregroundStyle(.rcTextPrimary)
        }
    }
}

// MARK: - Boot / database-rebuild overlay

/// The themed first-run sequence: a faux system fault that demands a "manual
/// override" to rebuild the star catalog, then shows the live survey progress.
/// The scrim is deliberately light so the stars flashing in behind read through.
private struct BootRebuildOverlay: View {
    let store: StoreOf<StarMapFeature>

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            card
                .frame(width: 440)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.rcHeadline)
                        .foregroundStyle(.rcTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.rcBody)
                        .foregroundStyle(.rcTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            phaseContent
        }
        .padding(Space.xl)
        .hudGlass()
    }

    @ViewBuilder private var phaseContent: some View {
        switch store.bootPhase {
        case .corruptionDetected:
            VStack(alignment: .leading, spacing: Space.m) {
                Text("FAULT 0x5A · STAR_SYSTEM_DB · INTEGRITY CHECK FAILED")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                if let error = store.surveyError {
                    Text("Last attempt failed: \(error)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    store.send(.manualOverrideTapped)
                } label: {
                    Text(store.surveyError == nil ? "Manual Override" : "Retry Manual Override")
                        .font(.rcBodyEmph)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.s)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.rcAccentOnColor)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(.rcAccent))
            }

        case .rebuilding, .complete:
            VStack(alignment: .leading, spacing: Space.s) {
                ProgressView(value: store.surveyFraction)
                    .tint(.rcAccent)
                HStack {
                    Text(progressLine)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                    Spacer()
                    Text("\(Int(store.surveyFraction * 100))%")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

        case .idle:
            EmptyView()
        }
    }

    private var progressLine: String {
        let total = store.surveyTotalPages ?? 0
        let stars = store.surveyStarCount.formatted()
        return store.bootPhase == .complete
            ? "\(stars) STARS RESTORED"
            : "PAGE \(store.surveyPagesDone) / \(total) · \(stars) STARS RECOVERED"
    }

    private var icon: String {
        switch store.bootPhase {
        case .complete: "checkmark.seal.fill"
        case .rebuilding: "arrow.triangle.2.circlepath"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch store.bootPhase {
        case .complete: .rcStatusReady
        case .rebuilding: .rcAccent
        default: .rcError
        }
    }

    private var title: String {
        switch store.bootPhase {
        case .complete: "Star system database restored"
        case .rebuilding: "Rebuilding star system database…"
        default: "Error during Replicant boot sequence: Database corruption detected!"
        }
    }

    private var message: String {
        switch store.bootPhase {
        case .complete: "Catalog reconstructed from deep survey. Resuming normal operation."
        case .rebuilding: "Manual override accepted. Reconstructing the catalog from a live deep-space survey."
        default: "Manual override required to rebuild the star system database."
        }
    }
}

// MARK: - Glass recipe + layer colors

extension View {
    /// The HUD glass card recipe (spec §2).
    func hudGlass(_ radius: CGFloat = Radius.card) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }
}

extension InfoLayer {
    /// Legend color, mapped to the design tokens (spec §2 swatch table).
    var legendColor: Color {
        switch self {
        case .presence: .rcAccent
        case .relay:    .rcAccent
        case .recon:    .rcTextSecondary
        case .life:     .rcStatusReady
        case .resource: .rcStatusWaiting
        case .npc:      .rcNPC
        }
    }
}

// MARK: - SceneKit bridge

struct StarMapSceneView: NSViewRepresentable {
    let store: StoreOf<StarMapFeature>
    /// Passed explicitly so SwiftUI re-runs `updateNSView` when focus or a
    /// recenter changes (reading them here registers the observation
    /// dependency and drives the imperative commands).
    let focus: StarMapFocus
    let resetToken: Int
    /// The charted stars, observed from the `Star` table. The scene diffs and
    /// renders new rows; `flashNew` flashes them in during a rebuild.
    let stars: [Star]
    let flashNew: Bool
    /// Whether stars accept selection/drill-in yet (after the rebuild).
    let interactive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> MapSCNView {
        context.coordinator.scene.scnView
    }

    func updateNSView(_ nsView: MapSCNView, context: Context) {
        let scene = context.coordinator.scene
        scene.apply(activeLayers: store.activeLayers)
        scene.apply(selection: store.selectedSystemID)
        scene.apply(autoRotate: store.autoRotate)
        scene.apply(resetToken: resetToken)
        scene.apply(focus: focus)
        scene.sync(stars: stars, flashNew: flashNew, interactive: interactive)
    }

    @MainActor
    final class Coordinator {
        let scene: GalaxyScene

        init(store: StoreOf<StarMapFeature>) {
            self.scene = GalaxyScene { intent in
                switch intent {
                case let .selectedSystem(id):
                    store.send(.systemTapped(id))
                case .userInteracted:
                    break   // idle/auto-yaw is managed inside the scene
                }
            }
        }
    }
}
