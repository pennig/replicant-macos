//
//  NewStarMapView.swift
//  NewStarMapFeature
//
//  The Metal galaxy map's content pane: the Metal field under a SwiftUI glass
//  HUD, ported from the SceneKit `StarMapView`'s `galaxyHUD`. Dark-only (spec §2),
//  drawn entirely from the UI design tokens.
//
//  Ported as-is: header, controls (survey / auto-rotate / recenter), the layer
//  rail (presentational — not wired to the renderer yet), the selected-system
//  dossier, and the themed first-run boot/rebuild overlay. Deferred with the
//  zoom-to-solar-system work: the system-focus HUD and the dossier's drill-in.
//

import ComposableArchitecture
import SQLiteData
import SwiftUI
import UI
import UniverseModels

public struct NewStarMapView: View {
    @Bindable var store: StoreOf<NewStarMapFeature>
    /// The charted galaxy, straight from SQLite — the same table the SceneKit map
    /// reads. Sorted by insertion order so new survey rows append deterministically.
    @FetchAll(UniverseModels.Star.order(by: \.createdAt)) private var surveyed

    public init(store: StoreOf<NewStarMapFeature>) {
        self.store = store
    }

    /// The render-domain terrain fed to the Metal view.
    private var stars: [Star] { surveyed.map(Star.init(surveyed:)) }
    private var chartedStarCount: Int { surveyed.count }

    /// The current-location system — the one nearest Sol (the origin), matching
    /// the renderer's gold player reticle. Used to flag the dossier.
    private var currentLocationID: String? {
        surveyed.min { lhs, rhs in distanceFromSol(lhs) < distanceFromSol(rhs) }?.designation
    }

    /// The selected star, resolved to its full presentation system via the live row.
    private var selectedSystem: GalaxySystem? {
        guard let designation = store.selectedStar?.name,
              let row = surveyed.first(where: { $0.designation == designation })
        else { return nil }
        return GalaxySystem(surveyed: row.item, isCurrentLocation: row.designation == currentLocationID)
    }

    public var body: some View {
        ZStack {
            MetalStarView(store: store, stars: stars)
                .ignoresSafeArea()

            galaxyHUD.transition(.opacity)

            // The themed first-run "database rebuild" sequence, over everything.
            if store.bootPhase != .idle {
                BootRebuildOverlay(store: store)
                    .transition(.opacity)
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.22), value: store.selectedStar)
        .animation(.easeInOut(duration: 0.22), value: store.activeFilterName)
        .animation(.easeInOut(duration: 0.4), value: store.bootPhase)
        .navigationTitle("Galaxy")
        .task { store.send(.task) }
    }

    // MARK: - Galaxy HUD

    private var galaxyHUD: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                Spacer()
                HStack(alignment: .bottom) {
                    if let system = selectedSystem {
                        SystemDossier(system: system) {
                            store.send(.selectionCleared)
                        }
                        .frame(maxWidth: 280)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer()
                    controls
                }
            }
            .padding(Space.l)

            // Active data-filter chip (Metal-specific, cycled with F), pinned top.
            if let filter = store.activeFilterName {
                VStack {
                    Text("Filter · \(filter)")
                        .font(.rcCaption)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.xs)
                        .hudGlass(Radius.control)
                        .padding(.top, Space.l)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    Spacer()
                }
            }

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
                    Text("Sector \(store.surveyPagesDone) / \(total)")
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

    private func distanceFromSol(_ star: UniverseModels.Star) -> Double {
        (star.positionX * star.positionX
            + star.positionY * star.positionY
            + star.positionZ * star.positionZ).squareRoot()
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
        if system.isCurrentLocation { return "Current Location" }
        let p = system.position
        let ly = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        return String(format: "%.1f ly", ly)
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

// MARK: - Boot / database-rebuild overlay

/// The themed first-run sequence: a faux system fault that demands a "manual
/// override" to rebuild the star catalog, then shows the live survey progress.
/// The scrim is deliberately light so the stars flashing in behind read through.
private struct BootRebuildOverlay: View {
    let store: StoreOf<NewStarMapFeature>

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
            : "SECTOR \(store.surveyPagesDone) / \(total) · \(stars) STARS RECOVERED"
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
        default: "Error loading galaxy map: database corruption detected!"
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

private extension View {
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

private extension InfoLayer {
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
