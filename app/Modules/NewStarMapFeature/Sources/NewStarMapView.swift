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
import CStarMapShaderTypes
import GameModels
import simd
import SQLiteData
import SwiftUI
import TravelUI
import UI
import UniverseModels

public struct NewStarMapView: View {
    @Bindable var store: StoreOf<NewStarMapFeature>
    /// The bridge the Metal renderer pushes ship pip screen positions to each
    /// frame. Held here but NOT read in `body` — only the sibling `ShipOverlayLayer`
    /// reads `.ships`, so a per-frame update re-renders just that overlay and never
    /// this view (which would otherwise rebuild the whole star terrain per frame).
    @State private var shipProjection = ShipProjectionModel()
    /// The charted galaxy, straight from SQLite — the same table the SceneKit map
    /// reads. Sorted by insertion order so new survey rows append deterministically.
    @FetchAll(UniverseModels.Star.order(by: \.createdAt)) private var surveyed
    /// Persisted per-system detail (planets/belts/scan), the same blobs the
    /// Locations catalog hydrates. The orrery reads the focused system from here.
    @FetchAll(SystemDetail.all) private var systemDetails
    /// The account's replicant roster — for the current-location system (the gold
    /// reticle follows `currentStar`) of the active replicant.
    @FetchAll(Replicant.all) private var replicants
    /// The live device roster — the source of the real FTL relay nodes (relay
    /// device locations) and the ships in transit (devices with a travel block).
    @FetchAll(Device.all) private var devices
    /// The persisted FTL mesh — the edges the reducer rebuilds off each relay's
    /// network view. Read straight from SQLite so the mesh draws instantly on
    /// launch and survives a moment where a relay's network read fails.
    @FetchAll(FTLLinkRecord.all) private var ftlLinkRecords

    public init(store: StoreOf<NewStarMapFeature>) {
        self.store = store
    }

    /// The render-domain terrain fed to the Metal view. The census `Star` row's
    /// exploration flag lags real scan state, so overlay the recon we actually
    /// hold in `systemDetails` — otherwise a fully-scanned system reads (and
    /// glyphs) as unexplored on the map.
    private var stars: [Star] {
        let current = currentStar
        let relays = relaySystems
        return surveyed.map { row in
            var s = Star(surveyed: row)
            switch detailRecon(row.designation) {
            case .scanned: s.scan = .full
            case .visited: if s.scan == .unexplored { s.scan = .partial }
            default: break
            }
            s.isCurrentLocation = row.designation == current
            s.hasFTLRelay = relays.contains(row.designation)
            return s
        }
    }
    private var chartedStarCount: Int { surveyed.count }

    /// The overlays handed to the renderer: the real FTL mesh links (persisted
    /// from each relay's backend network view) and the ships in transit (from the
    /// live device roster).
    private var overlays: StarMapOverlays {
        StarMapOverlays(ftlLinks: ftlLinkRecords.map(\.link), ships: ships)
    }

    /// The active replicant's current-location *system* designation (e.g. `AINALRAM`),
    /// where the gold player reticle sits. Prefers the session's active replicant;
    /// falls back to the sole replicant when only one is on the roster.
    private var currentStar: String? {
        let active = replicants.first { $0.replicantCode == store.activeReplicantCode }
        return (active ?? (replicants.count == 1 ? replicants.first : nil))?.currentStar
    }

    /// The active replicant's host device (its vessel), resolved from the live
    /// roster via `hostedDeviceCode`. Nil when there's no active replicant or the
    /// host isn't on the roster. Prefers the session's active replicant; falls
    /// back to the sole replicant, mirroring `currentStar`.
    private var activeHostDevice: Device? {
        let active = replicants.first { $0.replicantCode == store.activeReplicantCode }
            ?? (replicants.count == 1 ? replicants.first : nil)
        guard let code = active?.hostedDeviceCode else { return nil }
        return devices.first { $0.deviceCode == code }
    }

    /// Whether the active replicant's host can plot *interstellar* travel — a
    /// vessel carrying the `surge` feature. Gates the dossier's Travel button.
    /// Intra-system (`cruise`-only) travel is deferred until planets/moons are
    /// selectable on the map.
    private var canTravelFromHost: Bool {
        activeHostDevice?.features.contains("surge") == true
    }

    /// The relay-capable devices, reduced to their star systems — the FTL mesh
    /// nodes. Only `ftl_relay` devices participate; the `ftl_beacon` is not a mesh
    /// node (the backend refuses its network view).
    private var relayNodes: [RelayNode] {
        devices
            .filter { $0.deviceType == "ftl_relay" }
            .compactMap { device in
                device.location
                    .map(Self.systemDesignation)
                    .map { RelayNode(deviceCode: device.deviceCode, star: $0) }
            }
    }

    /// The set of systems holding one of the player's relays — the mesh node flag.
    private var relaySystems: Set<String> { Set(relayNodes.map(\.star)) }

    /// Ships in transit, built from devices carrying a live travel activity: the
    /// origin/destination *systems* and the real trip window. Skips a device whose
    /// endpoints or timing can't be resolved, or that isn't going anywhere.
    private var ships: [ShipRoute] {
        devices.compactMap { device -> ShipRoute? in
            guard let activity = device.derivedActivity, activity.kind == .travel,
                  let departedAt = activity.startedAt, let arrivesAt = activity.completesAt,
                  let snapshot = device.travelSnapshot,
                  let origin = snapshot.origin.map(Self.systemDesignation),
                  let destination = snapshot.destination.map(Self.systemDesignation),
                  origin != destination
            else { return nil }
            return ShipRoute(deviceCode: device.deviceCode, from: origin, to: destination,
                             departedAt: departedAt, arrivesAt: arrivesAt)
        }
    }

    /// deviceCode → deviceType for every device on the roster, so the ship overlay
    /// can resolve each pip's `device.<type>` glyph. Recomputed only when `body`
    /// re-evaluates (not per frame — `body` never reads `shipProjection.ships`).
    private var shipDeviceTypes: [String: String] {
        Dictionary(devices.map { ($0.deviceCode, $0.deviceType) }, uniquingKeysWith: { first, _ in first })
    }

    /// The device backing the selected ship's dossier, resolved from the live roster.
    private var selectedShipDevice: Device? {
        guard let code = store.selectedShipDeviceCode else { return nil }
        return devices.first { $0.deviceCode == code }
    }

    /// The star system a location code belongs to — the designation up to the
    /// first hyphen (`AINALRAM-1-L4` → `AINALRAM`, `SOL-3` → `SOL`).
    private static func systemDesignation(_ location: String) -> String {
        String(location.split(separator: "-").first ?? "")
    }

    /// Charted stars whose designation matches the live search query (case-
    /// insensitive substring). Prefix matches rank first, then nearer stars; the
    /// list is capped so the dropdown stays compact.
    private var searchResults: [Star] {
        let query = store.searchQuery.trimmingCharacters(in: .whitespaces).uppercased()
        guard !query.isEmpty else { return [] }
        return stars
            .filter { $0.name.uppercased().contains(query) }
            .sorted { lhs, rhs in
                let lPrefix = lhs.name.uppercased().hasPrefix(query)
                let rPrefix = rhs.name.uppercased().hasPrefix(query)
                if lPrefix != rPrefix { return lPrefix }
                return simd_length(lhs.position) < simd_length(rhs.position)
            }
            .prefix(8)
            .map { $0 }
    }

    /// Recon we actually hold for a system, from the denormalized `systemDetails`
    /// column (no JSON decode) — authoritative over the census row's stale flag.
    private func detailRecon(_ designation: String) -> Recon? {
        systemDetails.first { $0.designation == designation }
            .flatMap { Recon(rawValue: $0.recon) }
    }

    /// Exact planet count once a system is scanned (from its persisted roster);
    /// nil otherwise, so the HUD can fall back to the census estimate.
    private func exactPlanetCount(_ designation: String) -> Int? {
        guard detailRecon(designation) == .scanned,
              let detail = systemDetails.first(where: { $0.designation == designation }),
              let system = try? detail.system()
        else { return nil }
        return system.planets.count
    }

    /// The current-location system — the replicant's `currentStar`, matching the
    /// renderer's gold player reticle. Used to flag the dossier + search row.
    private var currentLocationID: String? { currentStar }

    /// The selected star as a presentation system, with recon upgraded from any
    /// real detail we hold (so a scanned system reads as scanned + is drillable).
    private var selectedSystem: GalaxySystem? {
        guard let designation = store.selectedStar?.name,
              let row = surveyed.first(where: { $0.designation == designation })
        else { return nil }
        var gs = GalaxySystem(surveyed: row.item, isCurrentLocation: row.designation == currentLocationID)
        if let recon = detailRecon(designation) { gs.recon = recon }
        return gs
    }

    /// The focused orrery model. At `.system` it's the whole system (real
    /// `StarSystem` when persisted, else a minimal star-only model so the sun
    /// appears immediately while the hydrate lands). At `.body` it's the drilled
    /// planet + its moons, decoded from the persisted parent system.
    private var focusedModel: SystemModel? {
        switch store.focus {
        case .galaxy:
            return nil
        case let .system(id):
            if let system = persistedSystem(id) {
                return OrreryMapping.systemModel(from: system)
            }
            guard let row = surveyed.first(where: { $0.designation == id }) else { return nil }
            return OrreryMapping.minimal(
                designation: id, position: row.item.position,
                spectralType: row.item.spectralType, color: row.item.color, name: nil)
        case let .body(bodyID):
            guard let sys = store.focus.systemDesignation,
                  let system = persistedSystem(sys),
                  let planet = system.planets.first(where: { $0.designation == bodyID })
            else { return nil }
            return OrreryMapping.bodyModel(planet: planet)
        }
    }

    /// The decoded persisted `StarSystem` for a designation, if we hold one.
    private func persistedSystem(_ designation: String) -> StarSystem? {
        systemDetails.first(where: { $0.designation == designation })
            .flatMap { try? $0.system() }
    }

    /// Window title reflecting the current focus level.
    private var navTitle: String {
        switch store.focus {
        case .galaxy:
            return "Galaxy"
        case .system:
            return focusedModel.map { "Galaxy · \($0.star.name ?? $0.star.designation)" } ?? "Galaxy"
        case .body:
            return focusedModel.map { "System · \($0.star.name ?? $0.star.designation)" } ?? "Galaxy"
        }
    }

    public var body: some View {
        ZStack {
            MetalStarView(store: store, stars: stars, overlays: overlays,
                          focus: store.focus, systemModel: focusedModel,
                          shipProjection: shipProjection)
                .ignoresSafeArea()

            // Tappable device icons over the ship pips. Renders nothing unless the
            // renderer is publishing projected ships (galaxy scale only); empty
            // areas capture no hits, so map gestures pass through.
            ShipOverlayLayer(
                projection: shipProjection,
                deviceTypes: shipDeviceTypes,
                selectedDeviceCode: store.selectedShipDeviceCode,
                onSelect: { store.send(.shipSelected($0)) }
            )
            .ignoresSafeArea()

            switch store.focus {
            case .galaxy:
                galaxyHUD.transition(.opacity)
            case .system, .body:
                if let model = focusedModel {
                    SystemHUD(
                        model: model,
                        level: { if case .body = store.focus { return .body } else { return .system } }(),
                        isTransitioning: store.isTransitioning,
                        onBack: { store.send(.zoomOutRequested) },
                        onScan: { store.send(.scanCurrentSystemTapped) },
                        onDrillBody: { store.send(.drillIntoBodyRequested($0)) }
                    )
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
        .animation(.easeInOut(duration: 0.5), value: store.focus)
        .animation(.easeInOut(duration: 0.22), value: store.selectedStar)
        .animation(.easeInOut(duration: 0.22), value: store.selectedShipDeviceCode)
        .animation(.easeInOut(duration: 0.15), value: store.searchQuery)
        .animation(.easeInOut(duration: 0.22), value: store.activeFilterName)
        .animation(.easeInOut(duration: 0.4), value: store.bootPhase)
        .navigationTitle(navTitle)
        .sheet(
            isPresented: Binding(
                get: { store.travelPreview != nil },
                set: { if !$0 { store.send(.travelPreviewDismissed) } }
            )
        ) {
            TravelPlanSheet(
                preview: store.travelPreview,
                onConfirm: { store.send(.travelPreviewConfirmed) },
                onDismiss: { store.send(.travelPreviewDismissed) }
            )
        }
        .task { store.send(.task) }
        // Rebuild + persist the mesh whenever the relay roster changes (and once on
        // appear). Relay liveness flips that don't change the roster are handled by
        // GameSync's relay event route, so the persisted mesh stays fresh even when
        // this view isn't on screen.
        .onChange(of: relayNodes, initial: true) { _, _ in
            store.send(.refreshMesh)
        }
    }

    // MARK: - Galaxy HUD

    private var galaxyHUD: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Space.m) {
                GalaxyNavigator(
                    chartedStarCount: chartedStarCount,
                    query: Binding(
                        get: { store.searchQuery },
                        set: { store.send(.searchQueryChanged($0)) }
                    ),
                    results: searchResults,
                    currentLocationID: currentLocationID,
                    onSelect: { store.send(.searchResultSelected($0)) }
                )
                Spacer()
                HStack(alignment: .bottom) {
                    if let device = selectedShipDevice {
                        ShipDossier(
                            device: device,
                            onViewDevice: { store.send(.viewDeviceRequested(device.deviceCode)) },
                            onClose: { store.send(.shipDeselected) }
                        )
                        .frame(width: 280)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    } else if let system = selectedSystem {
                        SystemDossier(
                            system: system,
                            exactPlanetCount: exactPlanetCount(system.id),
                            canDrill: system.recon != .aware && !store.isTransitioning,
                            canTravel: canTravelFromHost && !system.isCurrentLocation,
                            onDrill: { store.send(.drillInRequested(system.id)) },
                            onTravel: {
                                if let code = activeHostDevice?.deviceCode {
                                    store.send(.travelPreviewRequested(deviceCode: code, destination: system.id))
                                }
                            },
                            onClose: { store.send(.selectionCleared) }
                        )
                        .frame(width: 280)
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

}

// MARK: - Galaxy navigator (header + search)

/// The galaxy HUD's primary navigation lockup: the "Galaxy Explorer" title and
/// charted-star count over a search field, in one glass card. Typing filters the
/// charted catalog; picking a result (click or ↩ on the top hit) flies the camera
/// to that star. Uses the design system's field styling (`rcField`) and focus ring.
private struct GalaxyNavigator: View {
    let chartedStarCount: Int
    @Binding var query: String
    let results: [Star]
    let currentLocationID: String?
    let onSelect: (Star) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Galaxy Explorer")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                Text(chartedStarCount > 0 ? "\(chartedStarCount.formatted()) charted stars" : "Uncharted")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.rcTextTertiary)
                TextField("Search stars…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { onSelect(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.rcTextTertiary)
                            .padding(6)                   // enlarge the hit target…
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-6)                          // …without affecting layout
                }
            }
            .rcField(focused: searchFocused)

            if !query.isEmpty {
                if results.isEmpty {
                    Text("No charted stars match")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results, id: \.name) { star in
                            SearchResultRow(
                                star: star,
                                isCurrentLocation: star.name == currentLocationID,
                                onSelect: { onSelect(star) }
                            )
                        }
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(width: 280, alignment: .leading)
        .hudGlass()
    }
}

/// One search-result row: designation on the leading edge, distance (or the
/// current-location flag) trailing, with a hover highlight so it reads as tappable.
private struct SearchResultRow: View {
    let star: Star
    let isCurrentLocation: Bool
    let onSelect: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.s) {
                Text(star.name)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: Space.s)
                Text(trailing)
                    .font(.rcCaption)
                    .foregroundStyle(isCurrentLocation ? .rcAccent : .rcTextTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(.rcAccent.opacity(hovered ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var trailing: String {
        isCurrentLocation ? "Current Location" : String(format: "%.1f ly", simd_length(star.position))
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
    /// Exact count when the system is scanned; nil → show the census estimate.
    let exactPlanetCount: Int?
    let canDrill: Bool
    /// Whether the active replicant's host vessel can plot travel to this system
    /// (a surge-capable vessel, and not the current location). Drives the Travel
    /// button's presence.
    let canTravel: Bool
    let onDrill: () -> Void
    let onTravel: () -> Void
    let onClose: () -> Void

    /// "3" when we know exactly, "~2" when it's still an estimate.
    private var planetCountText: String {
        exactPlanetCount.map(String.init) ?? "~\(system.star.estimatedPlanets)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(system.name)
                        .font(.rcHeadlineMono)
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
                stat("Planets", planetCountText)
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

            Text(exactPlanetCount.map { "\(distanceText) · \($0) planets" }
                 ?? "\(distanceText) · ~\(system.star.estimatedPlanets) est. planets")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)

            if system.recon != .aware || canTravel {
                VStack(spacing: Space.xs) {
                    if system.recon != .aware {
                        Button(action: onDrill) {
                            Label("View system", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
                        }
                        .buttonStyle(RCButtonStyle(.secondary, fullWidth: true))
                        .disabled(!canDrill)
                    }
                    if canTravel {
                        Button(action: onTravel) {
                            Label("Travel", systemImage: "location.north.line")
                        }
                        .buttonStyle(RCButtonStyle(.primary, fullWidth: true))
                    }
                }
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

// MARK: - Ship dossier

/// The device dossier for a ship in transit, surfaced by tapping its pip icon. A
/// glass HUD card mirroring `SystemDossier`'s slot: identity + status, the live
/// leg it's flying, and a jump to the full Device inspector. System/location names
/// are designation codes, so they render in mono (spec rule).
private struct ShipDossier: View {
    let device: Device
    let onViewDevice: () -> Void
    let onClose: () -> Void

    /// "heaven_vessel" → "Heaven Vessel" (local — `DevicePresentation` lives in the
    /// Devices feature and isn't importable here).
    private var typeName: String {
        device.deviceType
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                glyphTile
                VStack(alignment: .leading, spacing: 2) {
                    Text(typeName)
                        .font(.rcHeadline)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    Text(device.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.rcTextTertiary)
                }
                .buttonStyle(.plain)
            }

            StatusBadge(device.statusBase, parameter: device.statusParameter)

            Divider().overlay(.rcSeparator)

            if let snapshot = device.travelSnapshot {
                legReadout(snapshot)
            } else if let location = device.location {
                HStack(spacing: Space.xs) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10)).foregroundStyle(.rcTextTertiary)
                    Text(device.locationName ?? location)
                        .font(.rcMonoSmall).foregroundStyle(.rcTextSecondary)
                }
            }

            Button(action: onViewDevice) {
                Label("View device", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(RCButtonStyle(.primary, fullWidth: true))
            .padding(.top, 2)
        }
        .padding(Space.m)
        .hudGlass()
    }

    private var glyphTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
                )
            Image.rcSymbol("device.\(device.deviceType)")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.rcTextPrimary)
        }
        .frame(width: 40, height: 40)
    }

    /// The active travel leg: origin → destination (designation codes, mono) and the
    /// arrival ETA, when the trip window is known.
    @ViewBuilder private func legReadout(_ snapshot: TravelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                if let origin = snapshot.origin {
                    Text(origin).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 9)).foregroundStyle(.rcTextTertiary)
                Text(snapshot.destination ?? "—")
                    .font(.rcBodyEmphMono).foregroundStyle(.rcTextPrimary)
            }
            .lineLimit(1)
            if let eta = device.derivedActivity?.completesAt {
                HStack(spacing: Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 10)).foregroundStyle(.rcTextTertiary)
                    Text("Arrives \(eta, format: .relative(presentation: .named))")
                        .font(.rcCaption).foregroundStyle(.rcTextSecondary)
                }
            }
        }
    }
}

// MARK: - System HUD (orrery focus)

/// Which orrery scale the HUD is describing — a whole system, or one planet and
/// its moons.
private enum OrreryLevel { case system, body }

/// The orrery-focus HUD: a central-body dossier (top-leading) and a satellites
/// list (bottom-trailing), with a Back control that zooms out one level. At system
/// level the satellite rows drill into a planet; at body level they list moons.
private struct SystemHUD: View {
    let model: SystemModel
    let level: OrreryLevel
    let isTransitioning: Bool
    let onBack: () -> Void
    let onScan: () -> Void
    let onDrillBody: (String) -> Void

    private var isBody: Bool { level == .body }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Space.m) {
                starCard
                Spacer()
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)

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
                Label(isBody ? "Back to System" : "Back to Galaxy", systemImage: "arrow.up.left")
                    .font(.rcCaption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.rcAccent)
            .disabled(isTransitioning)

            Divider().overlay(.rcSeparator)

            Text(model.star.name ?? model.star.designation)
                .font(.rcTitleMono).foregroundStyle(.rcTextPrimary)
            Text([model.star.designation, model.star.spectralType,
                  model.star.temperatureK.map { "\(Int($0)) K" }]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)

            if model.star.massSolar != nil || model.star.luminositySolar != nil {
                HStack(spacing: Space.l) {
                    if let m = model.star.massSolar { fact("Mass", String(format: "%.2f M☉", m)) }
                    if let l = model.star.luminositySolar { fact("Lum", String(format: "%.2f L☉", l)) }
                }
            }
            if let hz = model.star.habitableZone {
                fact("Habitable zone", String(format: "%.2f–%.2f AU", hz.innerAu, hz.outerAu))
            }
            HStack(spacing: Space.l) {
                if isBody {
                    fact("Moons", "\(model.planets.count)")
                } else {
                    fact("Planets", "\(model.planets.count)")
                    fact("Belts", model.belts.isEmpty ? "None"
                         : model.belts.compactMap(\.density).first.map { $0.capitalized } ?? "\(model.belts.count)")
                    // Scan is only meaningful at system level (fills HZ / outer system).
                    if model.star.habitableZone == nil {
                        Button(action: onScan) {
                            Label("Scan", systemImage: "dot.radiowaves.left.and.right").font(.rcCaption)
                        }
                        .buttonStyle(.plain).foregroundStyle(.rcAccent)
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: 280, alignment: .leading)
        .hudGlass()
    }

    private var bodiesCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(isBody ? "Moons" : "Bodies")
                .font(.rcSectionLabel)
                .textCase(.uppercase)
                .foregroundStyle(.rcTextTertiary)
            ForEach(model.planets) { planet in
                bodyRow(planet)
            }
            if let hazard = model.hazards.first {
                Divider().overlay(.rcSeparator)
                HStack(spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.rcError)
                    Text(hazard.title ?? hazard.objectType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.rcCaption).foregroundStyle(.rcTextSecondary)
                    Spacer()
                    if let d = hazard.deadline {
                        Text(d, format: .relative(presentation: .named))
                            .font(.rcMonoSmall).foregroundStyle(.rcError)
                    }
                }
            }
            Divider().overlay(.rcSeparator)
            fact("Devices", "\(model.deviceCount)")
        }
        .padding(Space.m)
        .frame(maxWidth: 240, alignment: .leading)
        .hudGlass()
    }

    /// One satellite row. At system level the row drills into the planet (chevron +
    /// tap → `onDrillBody`); at body level it's a static moon entry.
    @ViewBuilder private func bodyRow(_ planet: OrreryPlanet) -> some View {
        let content = HStack(spacing: Space.s) {
            Circle()
                .fill(planet.inHabitableZone ? .rcStatusReady : .rcTextSecondary)
                .frame(width: 7, height: 7)
            Text(planet.name.map { "\(planet.designation) · \($0)" } ?? planet.designation)
                .font(.rcMono).foregroundStyle(.rcTextPrimary)
            indicatorGlyphs(planet.indicators)
            if planet.moonCount > 0 {
                Text("\(planet.moonCount)☾").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
            Spacer()
            Text(planet.type ?? "—").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            if !isBody {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(.rcTextTertiary)
            }
        }
        .contentShape(Rectangle())

        if isBody {
            content
        } else {
            Button { onDrillBody(planet.designation) } label: { content }
                .buttonStyle(.plain)
                .disabled(isTransitioning)
        }
    }

    @ViewBuilder private func indicatorGlyphs(_ ind: BodyIndicators) -> some View {
        HStack(spacing: 3) {
            if ind.contains(.life) { icon("leaf.fill", .rcStatusReady) }
            if ind.contains(.device) { icon("cpu", .rcAccent) }
            if ind.contains(.salvage) { icon("wrench.adjustable", .rcStatusWaiting) }
            if ind.contains(.miningSite) { icon("hammer.fill", .rcStatusWaiting) }
            if ind.contains(.inventory) { icon("shippingbox.fill", .rcTextSecondary) }
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 9)).foregroundStyle(color)
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
            .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
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
