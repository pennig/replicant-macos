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
    /// The bridge the renderer pushes projected device-cluster badge positions to each
    /// frame. Held here but NOT read in `body` — only `LocationClusterLayer` reads
    /// `.clusters`, so a per-frame update re-renders just that overlay.
    @State private var clusterProjection = DeviceClusterProjectionModel()
    /// The bridge the renderer pushes inbound/outbound transit callout positions to each
    /// frame. Held here but NOT read in `body` — only `TransitCalloutLayer` reads
    /// `.callouts`, so a per-frame update re-renders just that overlay.
    @State private var transitProjection = TransitProjectionModel()
    /// Memoizes the focused system's blob decode across body evaluations (see
    /// `SystemDecodeCache`). Reference type: reading through it never invalidates.
    @State private var decodeCache = SystemDecodeCache()
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
    /// Open operations, for the travel route frozen at dispatch. The live `travel`
    /// block lists only remaining legs and goes stale; the stored command response
    /// has the whole route with resolved location codes — and it's what the sidebar
    /// and device detail already read, so reading it here is what keeps all three
    /// naming the same destination.
    @FetchAll(Operation.order { $0.startedAt.desc() }) private var operations
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
        // One O(details) pass up front instead of a linear `systemDetails` scan
        // per star row — per-row `detailRecon` made this O(stars × details), and
        // it re-ran (on the main thread) for every observed table change.
        let recon = Dictionary(
            systemDetails.compactMap { d in Recon(rawValue: d.recon).map { (d.designation, $0) } },
            uniquingKeysWith: { first, _ in first })
        return surveyed.map { row in
            var s = Star(surveyed: row)
            switch recon[row.designation] {
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
                  let departedAt = activity.startedAt, let arrivesAt = activity.completesAt
            else { return nil }
            // The same itinerary the sidebar and device detail read: the whole route
            // frozen at dispatch when we have it, else the device's remaining-legs
            // block — with the backend's bare-system proxy codes resolved, so a trip
            // to "ASTELLIO" anchors on ASTELLIO-1-L4 and not on the star.
            let stored = operations.first {
                $0.entityCode == device.deviceCode && $0.status.isOpen
                    && $0.kind == OperationKind.travel.rawValue
            }?.travelSnapshot
            guard let snapshot = TravelSnapshot.itinerary(stored: stored, live: device.travelSnapshot)?
                    .resolvingSystemProxies,
                  let origin = snapshot.origin.map(TravelSnapshot.systemDesignation),
                  let destination = snapshot.destination.map(TravelSnapshot.systemDesignation),
                  origin != destination
            else { return nil }
            // Per-leg route (location-level) so the renderer places the ship along its
            // real multi-leg path — parking at a star during intra-system cruise legs and
            // spanning stars on a surge/jump. Legs missing endpoints are dropped; an empty
            // set falls back to a single origin→destination segment.
            let legs = snapshot.legs.compactMap { leg -> RouteLeg? in
                guard let f = leg.from, let t = leg.to else { return nil }
                return RouteLeg(from: f, to: t, seconds: leg.timeSeconds)
            }
            return ShipRoute(deviceCode: device.deviceCode, deviceType: device.deviceType,
                             from: origin, to: destination,
                             departedAt: departedAt, arrivesAt: arrivesAt, legs: legs)
        }
    }

    /// deviceCode → deviceType for every device on the roster, so the transit
    /// callout cards can resolve each ship's `device.<type>` glyph. (The ship
    /// icons themselves are GPU-drawn now and carry their type on `ShipRoute`.)
    private var shipDeviceTypes: [String: String] {
        Dictionary(devices.map { ($0.deviceCode, $0.deviceType) }, uniquingKeysWith: { first, _ in first })
    }

    /// The device backing the selected ship's dossier, resolved from the live roster.
    private var selectedShipDevice: Device? {
        guard let code = store.selectedShipDeviceCode else { return nil }
        return devices.first { $0.deviceCode == code }
    }

    /// The star system a location code belongs to — the designation up to the
    /// first hyphen (`AINALRAM-1-L4` → `AINALRAM`, `SOL-3` → `SOL`). Delegates to
    /// the GameModels definition so the map and the travel-itinerary normalization
    /// can never disagree about where a system designation ends.
    private static func systemDesignation(_ location: String) -> String {
        TravelSnapshot.systemDesignation(location)
    }

    /// Charted stars whose designation matches the live search query (case-
    /// insensitive substring). Prefix matches rank first, then nearer stars; the
    /// list is capped so the dropdown stays compact. Takes the already-built
    /// terrain so it never rebuilds the star array.
    private func searchResults(in stars: [Star]) -> [Star] {
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
              let system = decodeCache.system(for: detail)
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
            return OrreryMapping.bodyModel(planet: planet, options: store.planeOptions)
        }
    }

    /// The decoded persisted `StarSystem` for a designation, if we hold one.
    /// Decodes through `decodeCache`, so the several callers that need the focused
    /// system within one body evaluation (and across evaluations while the row is
    /// unchanged) share ONE decode of the blob instead of repeating it.
    private func persistedSystem(_ designation: String) -> StarSystem? {
        systemDetails.first(where: { $0.designation == designation })
            .flatMap { decodeCache.system(for: $0) }
    }

    /// The system the current focus sits in (nil in the galaxy).
    private var focusedSystemDesignation: String? {
        switch store.focus {
        case .galaxy: return nil
        case let .system(id): return id
        case .body: return store.focus.systemDesignation
        }
    }

    /// Device-presence clusters for the focused system, grouped by the anchor the current
    /// level draws (a moon rolls up to its planet at system level). Merges the live
    /// `Device` roster (own, authoritative, live status) with the persisted scan blob
    /// (others, coarse), deduped by device code — own wins. Empty in the galaxy. Fed to
    /// the renderer (badge placement) and the dossier (device list).
    private func deviceClusters(model focusedModel: SystemModel?) -> [DeviceCluster] {
        guard let model = focusedModel, let sys = focusedSystemDesignation else { return [] }
        // A transform-free layout: only its code dispatch (planet/moon/belt/Lagrange/…)
        // matters for grouping, not the world coordinates.
        let layout = OrreryLayout(model: model, center: .zero, scale: 1, reveal: 1, time: 0)
        // Own devices (authoritative) — every roster device located in this system.
        let own = devices.compactMap { d -> DeviceClustering.Input? in
            guard let loc = d.location, Self.systemDesignation(loc) == sys else { return nil }
            return DeviceClustering.Input(deviceCode: d.deviceCode, deviceType: d.deviceType,
                                          status: d.status, location: loc)
        }
        // Other players' devices from the persisted blob. Planet/moon come from the system
        // scan; belt/Lagrange/structure rosters arrive via the per-location hydrate fired
        // on selection (they're absent from the scan blob).
        var others: [DeviceClustering.Input] = []
        func located(_ ld: [LocatedDevice], at location: String) -> [DeviceClustering.Input] {
            ld.map { .init(deviceCode: $0.deviceCode, deviceType: $0.deviceType,
                           status: $0.status, location: location) }
        }
        if let system = persistedSystem(sys) {
            for p in system.planets {
                others += located(p.devices, at: p.designation)
                others += p.lagrange.flatMap { located($0.devices, at: $0.designation) }
                for m in p.moons { others += located(m.devices, at: m.designation) }
            }
            others += system.belts.flatMap { located($0.devices, at: $0.designation) }
            others += system.structures.flatMap { located($0.devices, at: $0.designation) }
        }
        return DeviceClustering.clusters(own: own, others: others, layout: layout)
    }

    /// The mining sites / salvage / stored inventory at a location, dug from the persisted
    /// system blob — surfaced in the location dossier. Resolves a planet, moon, belt, or
    /// structure by designation. Nil when we hold no detail for it.
    private func locationDetail(for code: String) -> LocationDetail? {
        guard let sys = focusedSystemDesignation, let system = persistedSystem(sys) else { return nil }
        if let p = system.planets.first(where: { $0.designation == code }) {
            return LocationDetail(miningSites: p.sites, salvage: p.salvage, inventory: p.inventory)
        }
        for p in system.planets {
            if let m = p.moons.first(where: { $0.designation == code }) {
                return LocationDetail(miningSites: m.sites, salvage: m.salvage, inventory: m.inventory)
            }
        }
        if let b = system.belts.first(where: { $0.designation == code }) {
            return LocationDetail(miningSites: b.sites, salvage: [], inventory: b.inventory)
        }
        if let s = system.structures.first(where: { $0.designation == code }) {
            return LocationDetail(miningSites: [], salvage: [], inventory: s.inventory)
        }
        return nil
    }

    /// Window title reflecting the current focus level. Takes the already-computed
    /// focused model so it never re-derives (and re-decodes) it.
    private func navTitle(model: SystemModel?) -> String {
        switch store.focus {
        case .galaxy:
            return "Galaxy"
        case .system:
            return model.map { "Galaxy · \($0.star.name ?? $0.star.designation)" } ?? "Galaxy"
        case .body:
            return model.map { "System · \($0.star.name ?? $0.star.designation)" } ?? "Galaxy"
        }
    }

    public var body: some View {
        // Derived data computed ONCE per evaluation and threaded through. As
        // computed properties these were re-derived at every use site — the
        // terrain twice, the focused model (a JSON blob decode) up to four times,
        // the clusters twice — on every observed table change, all on the main
        // thread.
        let terrain = stars
        let model = focusedModel
        let clusters = deviceClusters(model: model)
        ZStack {
            // Ship icons draw inside the Metal frame itself (see `encodeShipIcons`)
            // — no SwiftUI overlay to fall out of sync; clicks/hover route through
            // the AppKit input layer's `pickShip`.
            MetalStarView(store: store, stars: terrain, overlays: overlays,
                          focus: store.focus, systemModel: model,
                          deviceClusters: clusters,
                          clusterProjection: clusterProjection,
                          transitProjection: transitProjection)
                .ignoresSafeArea()

            // Device-presence badges over occupied orrery locations (system focus only;
            // the renderer emits nothing in the galaxy). Tapping selects the location,
            // surfacing its device list in the dossier.
            LocationClusterLayer(
                projection: clusterProjection,
                selectedLocation: store.selectedLocation,
                onSelect: { store.send(.locationSelected($0)) }
            )
            .ignoresSafeArea()

            // Inbound/outbound travel cards over the top of each dotted transit riser
            // (system focus only). Tapping selects the ship, like the ship icons.
            TransitCalloutLayer(
                projection: transitProjection,
                deviceTypes: shipDeviceTypes,
                selectedDeviceCode: store.selectedShipDeviceCode,
                onSelect: { store.send(.shipSelected($0)) }
            )
            .ignoresSafeArea()

            switch store.focus {
            case .galaxy:
                galaxyHUD(terrain: terrain).transition(.opacity)
            case .system, .body:
                if let model {
                    SystemHUD(
                        model: model,
                        level: { if case .body = store.focus { return .body } else { return .system } }(),
                        isTransitioning: store.isTransitioning,
                        selectedLocation: store.selectedLocation,
                        clusters: clusters,
                        locationDetail: store.selectedLocation.flatMap(locationDetail(for:)),
                        onBack: { store.send(.zoomOutRequested) },
                        onScan: { store.send(.scanCurrentSystemTapped) },
                        onDrillBody: { store.send(.drillIntoBodyRequested($0)) },
                        onSelectLocation: { store.send(.locationSelected($0)) },
                        onDismissLocation: { store.send(.selectionCleared) },
                        onViewDevice: { store.send(.viewDeviceRequested($0)) }
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
        .animation(.easeInOut(duration: 0.22), value: store.selectedLocation)
        .animation(.easeInOut(duration: 0.15), value: store.searchQuery)
        .animation(.easeInOut(duration: 0.22), value: store.activeFilterName)
        .animation(.easeInOut(duration: 0.4), value: store.bootPhase)
        .navigationTitle(navTitle(model: model))
        .navigationSubtitle(store.focus == .galaxy ? Text("^[\(chartedStarCount) known star](inflect: true)") : Text(""))
        // Item-driven (not `isPresented:`) so plotting travel for one system then
        // another in quick succession re-presents reliably — keyed on the
        // preview's identity, SwiftUI swaps sheets even when the change lands
        // mid-dismiss-animation, which a bool toggled off→on silently drops.
        .sheet(
            item: Binding(
                get: { store.travelPreview },
                set: { if $0 == nil { store.send(.travelPreviewDismissed) } }
            )
        ) { _ in
            TravelPlanSheet(
                preview: store.travelPreview,
                onConfirm: { store.send(.travelPreviewConfirmed) },
                onDismiss: { store.send(.travelPreviewDismissed) }
            )
        }
        .task { store.send(.task) }
        // Refresh the mesh whenever the relay roster changes (and once on appear).
        // The initial fire passes old == new, so the reducer can tell "pane
        // appeared" (freshness-gated rebuild) from a genuine roster change
        // (debounced invalidate). Relay liveness flips that don't change the
        // roster are handled by GameSync's relay event route, so the persisted
        // mesh stays fresh even when this view isn't on screen.
        .onChange(of: relayNodes, initial: true) { old, new in
            store.send(.refreshMesh(rosterChanged: old != new))
        }
    }

    // MARK: - Galaxy HUD

    private func galaxyHUD(terrain: [Star]) -> some View {
        ZStack {
            VStack(alignment: .leading, spacing: Space.m) {
                GalaxyNavigator(
                    query: Binding(
                        get: { store.searchQuery },
                        set: { store.send(.searchQueryChanged($0)) }
                    ),
                    results: searchResults(in: terrain),
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
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Surveying…").font(.rcCaption).foregroundStyle(.rcTextSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                Button {
                    store.send(.surveyButtonTapped)
                } label: {
                    Label("Survey galaxy", systemImage: "dot.radiowaves.left.and.right")
                        .font(.rcCaption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.isOnCooldown ? .rcTextTertiary : .rcAccent)
                .disabled(store.isOnCooldown)

                if let until = store.surveyCooldownUntil {
                    // Live-updating relative countdown; the reducer clears the
                    // cooldown (re-enabling the button) the moment it lifts.
                    Text("Available \(Text(until, style: .relative))")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                } else if let error = store.surveyError {
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

/// The galaxy HUD's primary navigation lockup: a search field  in one glass card.
/// Typing filters the charted catalog; picking a result (click or ↩ on the top hit) flies
/// the camera to that star. Uses the design system's field styling (`rcField`) and focus ring.
private struct GalaxyNavigator: View {
    @Binding var query: String
    let results: [Star]
    let currentLocationID: String?
    let onSelect: (Star) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(.rcTextTertiary)
                TextField("Search stars…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { onSelect(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: IconSize.m))
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
            RCSectionHeader("Layers")
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
                    .font(.system(size: IconSize.m))
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
                Image(systemName: reconSymbol).font(.system(size: IconSize.s))
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

    /// "heaven_vessel" → "HEAVEN Vessel" via the shared GameModels helper, so the
    /// special-casing rules live in one place.
    private var typeName: String {
        BlueprintPresentation.displayName(device.deviceType)
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
                        .font(.system(size: IconSize.s)).foregroundStyle(.rcTextTertiary)
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
                        .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                )
            Image.rcSymbol("device.\(device.deviceType)")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: IconSize.hero, weight: .regular))
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
                    .font(.system(size: IconSize.s)).foregroundStyle(.rcTextTertiary)
                Text(snapshot.destination ?? "—")
                    .font(.rcBodyEmphMono).foregroundStyle(.rcTextPrimary)
            }
            .lineLimit(1)
            if let eta = device.derivedActivity?.completesAt {
                HStack(spacing: Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: IconSize.s)).foregroundStyle(.rcTextTertiary)
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
/// A location's mining/salvage/inventory detail for the dossier, dug from the persisted
/// system blob (the orrery `SystemModel` carries only presence flags).
private struct LocationDetail: Equatable {
    var miningSites: [ResourceSite]
    var salvage: [SalvageSite]
    var inventory: [InventoryItem]
    var isEmpty: Bool { miningSites.isEmpty && salvage.isEmpty && inventory.isEmpty }
}

private struct SystemHUD: View {
    let model: SystemModel
    let level: OrreryLevel
    let isTransitioning: Bool
    /// The location the player picked in the orrery (planet/moon/belt/Lagrange/
    /// structure/star), driving the location dossier. Nil hides it.
    let selectedLocation: String?
    /// Device-presence clusters for this system, so the dossier can list the devices at
    /// the selected location (grouped by the same anchor the badges use).
    let clusters: [DeviceCluster]
    /// Mining/salvage/inventory detail for the selected location (nil when none held).
    let locationDetail: LocationDetail?
    let onBack: () -> Void
    let onScan: () -> Void
    let onDrillBody: (String) -> Void
    /// Select a location from the roster list. This is the ONLY way to reach a swarm
    /// moon: swarm members are not pickable in the 3D view, so the list is their
    /// interaction surface (see the many-moon spec).
    let onSelectLocation: (String) -> Void
    let onDismissLocation: () -> Void
    let onViewDevice: (String) -> Void

    private var isBody: Bool { level == .body }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Space.m) {
                starCard
                Spacer()
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Location dossier — bottom-leading, matching the galaxy system dossier's
            // position. Present only while a location is picked.
            VStack {
                Spacer()
                HStack {
                    locationDossier
                    Spacer()
                }
            }
            .padding(Space.l)

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

    /// The picked location's dossier — kind, designation (mono), and the basic facts we
    /// already hold in the orrery model. Device rosters, sites, and inventory land in
    /// Phases 3 & 5. Nil selection (or an unresolved code) renders nothing.
    @ViewBuilder private var locationDossier: some View {
        if let code = selectedLocation, let info = resolveLocation(code) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    RCSectionHeader(info.kind)
                    Spacer()
                    Button(action: onDismissLocation) {
                        Image(systemName: "xmark").font(.system(size: IconSize.s, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.rcTextTertiary)
                }
                Text(info.title).font(.rcHeadlineMono).foregroundStyle(.rcTextPrimary)
                if let sub = info.subtitle {
                    Text(sub).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
                }
                if !info.facts.isEmpty {
                    // A scanned planet or moon now carries up to six facts, which one
                    // HStack would run straight off the 280pt card. Two columns wrap
                    // instead, left-aligned so the labels line up down the card.
                    let rows = Array(stride(from: 0, to: info.facts.count, by: 2))
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(rows, id: \.self) { start in
                            HStack(alignment: .top, spacing: Space.l) {
                                ForEach(start..<min(start + 2, info.facts.count), id: \.self) { i in
                                    fact(info.facts[i].label, info.facts[i].value)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                // Keep a lone trailing fact in the left column.
                                if start + 2 > info.facts.count {
                                    Spacer(minLength: 0).frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
                if !info.indicators.isEmpty { indicatorGlyphs(info.indicators) }
                detailSections
            }
            .padding(Space.m)
            .frame(width: 280, alignment: .leading)
            .hudGlass()
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// The selected location's contents — devices, mining sites, salvage, and stored
    /// inventory — in one scroll area so a busy location never overruns the card.
    @ViewBuilder private var detailSections: some View {
        let devices = selectedLocation.flatMap { code in
            clusters.first { $0.anchorCode == code }?.devices
        } ?? []
        let hasDetail = locationDetail.map { !$0.isEmpty } ?? false
        if !devices.isEmpty || hasDetail {
            Divider().overlay(.rcSeparator)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if !devices.isEmpty { deviceSection(devices) }
                    if let d = locationDetail {
                        if !d.miningSites.isEmpty { miningSection(d.miningSites) }
                        if !d.salvage.isEmpty { salvageSection(d.salvage) }
                        if !d.inventory.isEmpty { inventorySection(d.inventory) }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    @ViewBuilder private func sectionHeader(_ text: String) -> some View {
        RCSectionHeader(text)
    }

    @ViewBuilder private func deviceSection(_ devices: [ClusterDevice]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            sectionHeader("Devices · \(devices.count)")
            ForEach(devices) { deviceRow($0) }
        }
    }

    @ViewBuilder private func miningSection(_ sites: [ResourceSite]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            sectionHeader("Mining · \(sites.count)")
            ForEach(sites) { site in
                VStack(alignment: .leading, spacing: 0) {
                    Text(site.name ?? site.designation).font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
                    let live = resourceSummary(site.remaining)
                    Text(live.isEmpty ? "Depleted" : live)
                        .font(.rcCaption).foregroundStyle(live.isEmpty ? .rcTextTertiary : .rcStatusWaiting)
                }
            }
        }
    }

    @ViewBuilder private func salvageSection(_ sites: [SalvageSite]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            sectionHeader("Salvage · \(sites.count)")
            ForEach(sites) { site in
                VStack(alignment: .leading, spacing: 0) {
                    Text(site.name ?? site.salvageType?.replacingOccurrences(of: "_", with: " ").capitalized ?? site.designation)
                        .font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
                    Text(site.depleted ? "Depleted" : site.resourcesAvailable.joined(separator: ", "))
                        .font(.rcCaption).foregroundStyle(site.depleted ? .rcTextTertiary : .rcStatusWaiting)
                }
            }
        }
    }

    @ViewBuilder private func inventorySection(_ items: [InventoryItem]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            sectionHeader("Inventory")
            ForEach(items.sorted { $0.quantity > $1.quantity }, id: \.resourceType) { item in
                HStack {
                    Text(item.resourceType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.rcCaption).foregroundStyle(.rcTextSecondary)
                    Spacer()
                    Text("\(Int(item.quantity))").font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
                }
            }
        }
    }

    /// The names of resources with any percentage remaining, comma-joined (empty ⇒ spent).
    private func resourceSummary(_ remaining: [String: Double]) -> String {
        remaining.filter { $0.value > 0 }.keys.sorted()
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
            .joined(separator: ", ")
    }

    @ViewBuilder private func deviceRow(_ dev: ClusterDevice) -> some View {
        HStack(spacing: Space.s) {
            Image.rcSymbol("device.\(dev.deviceType)")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: IconSize.s))
                .foregroundStyle(dev.isOwn ? Color.rcAccent : .rcTextSecondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(dev.deviceCode).font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
                if let s = dev.status, !s.isEmpty {
                    Text(s.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.rcCaption).foregroundStyle(.rcTextTertiary)
                }
            }
            Spacer()
            if dev.isOwn {
                Button("View") { onViewDevice(dev.deviceCode) }
                    .buttonStyle(.plain).font(.rcCaption).foregroundStyle(.rcAccent)
            } else {
                Text("Foreign").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
        }
    }

    private struct LocationDossierInfo {
        var kind: String
        var title: String
        var subtitle: String?
        var facts: [(label: String, value: String)]
        var indicators: BodyIndicators
    }

    /// Resolve a picked location code against the current orrery `model` into its
    /// dossier fields. Level-aware: an orbiter is a planet at system level, a moon at
    /// body level (promoted, in `model.planets`, or a swarm member, in `model.swarm`);
    /// the centre is the star (system) or the drilled body (body level).
    private func resolveLocation(_ code: String) -> LocationDossierInfo? {
        if code == model.star.designation {
            return LocationDossierInfo(
                kind: isBody ? "Body" : "Star",
                title: model.star.name ?? model.star.designation,
                subtitle: model.star.spectralType, facts: [], indicators: [])
        }
        if let p = model.planets.first(where: { $0.id == code }) {
            var facts: [(String, String)] = []
            if let t = p.type { facts.append(("Type", t)) }
            if !isBody { facts.append(("Orbit", String(format: "%.2f AU", p.orbitalDistanceAu))) }
            if !isBody, p.moonCount > 0 { facts.append(("Moons", "\(p.moonCount)")) }
            if !isBody {
                // System level: the body is a planet. Each fact appears only when the
                // scan actually reported it, so an unscanned world shows none of them.
                if p.rings != nil { facts.append(("Rings", "Yes")) }
                if let h = p.spin.rotationHours { facts.append(("Day", BodyFactFormat.hours(abs(h)))) }
                facts.append(("Year", BodyFactFormat.days(p.periodDays)))
                if let t = p.spin.tiltDeg {
                    facts.append(("Tilt", String(format: "%.1f°", t)
                        + (p.spin.isRetrograde ? " · retrograde" : "")))
                }
            } else {
                // Body level: the body is a moon.
                if let km = p.orbitalDistanceKm { facts.append(("Orbit", BodyFactFormat.km(km))) }
                facts.append(("Period", BodyFactFormat.hours(p.periodDays * 24)))
                if p.spin.tidallyLocked { facts.append(("Rotation", "Tidally locked")) }
                if let air = p.atmosphere.label { facts.append(("Atmosphere", air)) }
                if p.hasSubsurfaceOcean { facts.append(("Ocean", "Subsurface")) }
            }
            return LocationDossierInfo(
                kind: isBody ? "Moon" : "Planet",
                title: p.name.map { "\(p.designation) · \($0)" } ?? p.designation,
                subtitle: p.inHabitableZone ? "In habitable zone" : nil,
                facts: facts, indicators: p.indicators)
        }
        // Swarm moons only exist at body level and carry a smaller field set than a
        // promoted moon (no rings/tilt/atmosphere) — the roster is their only entry
        // point, so they must still resolve here or picking one from the list would
        // select a code the dossier can't show.
        if let m = model.swarm.first(where: { $0.id == code }) {
            var facts: [(String, String)] = []
            if let t = m.type { facts.append(("Type", t)) }
            facts.append(("Period", BodyFactFormat.hours(m.periodDays * 24)))
            return LocationDossierInfo(
                kind: "Moon",
                title: m.name.map { "\(m.designation) · \($0)" } ?? m.designation,
                subtitle: nil,
                facts: facts, indicators: [])
        }
        if let b = model.belts.first(where: { $0.id == code }) {
            var facts: [(String, String)] = []
            if let d = b.density { facts.append(("Density", d.capitalized)) }
            return LocationDossierInfo(kind: "Asteroid Belt", title: b.designation,
                                       subtitle: nil, facts: facts, indicators: [])
        }
        // Recognize a Lagrange point by its grammar (`…-L[1-5]`), not the `planet.lagrange`
        // array — that only fills via per-location hydration, but a device badge (and thus
        // a selectable code) can resolve from the parent planet alone.
        if let n = OrreryMapping.lPointNumber(code) {
            return LocationDossierInfo(kind: "Lagrange Point", title: code,
                                       subtitle: "L\(n) · \(OrreryLayout.parent(of: code))",
                                       facts: [], indicators: [])
        }
        if let s = model.structures.first(where: { $0.id == code }) {
            return LocationDossierInfo(
                kind: s.kind.replacingOccurrences(of: "_", with: " ").capitalized,
                title: code, subtitle: nil, facts: [], indicators: [])
        }
        return nil
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

    /// Max height for the roster list before it scrolls. A 59-moon roster would
    /// otherwise grow the card past the window.
    private static let rosterMaxHeight: CGFloat = 280

    private var bodiesCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader(isBody ? "Moons" : "Bodies")
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(model.planets) { planet in
                        bodyRow(planet)
                    }
                    if !model.swarm.isEmpty {
                        Divider().overlay(.rcSeparator)
                        HStack {
                            Text("Minor bodies")
                                .font(.rcCaption).foregroundStyle(.rcTextSecondary)
                            Spacer()
                            Text("\(model.swarm.count)")
                                .font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
                        }
                        ForEach(model.swarm) { moon in
                            swarmRow(moon)
                        }
                    }
                }
            }
            .frame(maxHeight: Self.rosterMaxHeight)
            if let hazard = model.hazards.first {
                Divider().overlay(.rcSeparator)
                HStack(spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: IconSize.s)).foregroundStyle(.rcError)
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

    /// One swarm-moon row. Selecting it drives the shared location dossier (and, via
    /// `selectedLocation`, the renderer's highlight) — the swarm's only entry point.
    @ViewBuilder private func swarmRow(_ moon: SwarmMoon) -> some View {
        let selected = selectedLocation == moon.designation
        Button { onSelectLocation(moon.designation) } label: {
            HStack(spacing: Space.s) {
                Circle()
                    .fill(selected ? .rcAccent : .rcTextTertiary)
                    .frame(width: 5, height: 5)
                Text(moon.name.map { "\(moon.designation) · \($0)" } ?? moon.designation)
                    .font(.rcMonoSmall)
                    .foregroundStyle(selected ? .rcTextPrimary : .rcTextSecondary)
                Spacer()
                Text(moon.type ?? "—").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One satellite row. At system level the row drills into the planet (chevron +
    /// tap → `onDrillBody`); at body level it selects the moon (tap → `onSelectLocation`).
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
                    .font(.system(size: IconSize.s)).foregroundStyle(.rcTextTertiary)
            }
        }
        .contentShape(Rectangle())

        if isBody {
            // At body level a row selects the moon (there is nothing deeper to drill
            // into), driving the same dossier a 3D pick would.
            Button { onSelectLocation(planet.designation) } label: { content }
                .buttonStyle(.plain)
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
        Image(systemName: name).font(.system(size: IconSize.s)).foregroundStyle(color)
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
                    .font(.system(size: IconSize.hero, weight: .semibold))
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
        case .rebuilding:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text(progressLine)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
            }

        case .complete:
            Text(progressLine)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)

        case .idle:
            EmptyView()
        }
    }

    private var progressLine: String {
        let stars = store.surveyStarCount.formatted()
        return store.bootPhase == .complete
            ? "\(stars) STARS CHARTED"
            : "DOWNLOADING CATALOGUE…"
    }

    private var icon: String {
        store.bootPhase == .complete ? "checkmark.seal.fill" : "sparkles"
    }

    private var iconColor: Color {
        store.bootPhase == .complete ? .rcStatusReady : .rcAccent
    }

    private var title: String {
        store.bootPhase == .complete ? "Star catalogue ready" : "Charting the galaxy…"
    }

    private var message: String {
        store.bootPhase == .complete
            ? "The full star catalogue is loaded. Resuming normal operation."
            : "Downloading the full star catalogue."
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
                    .strokeBorder(.white.opacity(0.10), lineWidth: Hairline.thin)
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
