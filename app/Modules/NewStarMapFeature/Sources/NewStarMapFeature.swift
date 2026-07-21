//
//  NewStarMapFeature.swift
//  NewStarMapFeature
//
//  The Metal star map reducer. Like the SceneKit `StarMapFeature`, it owns the
//  declarative UI/intent state — selection, the active data-filter label, the
//  info-layer set, auto-rotate, a camera-recenter token, and the first-run survey
//  / boot sequence. The retained render state (camera pose, relevance field,
//  overlay toggles, animations) lives imperatively inside `StarFieldRenderer`
//  behind the `MetalStarView` representable; the input layer forwards the outcome
//  of each interaction here as an action.
//
//  The survey + boot logic is ported from `StarMapFeature`: both features read
//  and write the same persisted `Star` table, so surveying from either fills the
//  shared galaxy.
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData
import UniverseModels

@Reducer
public struct NewStarMapFeature {
    @ObservableState
    public struct State: Equatable {
        /// The star surfaced by the last pick (single-click re-aim or double-click
        /// dive); nil after a clear/home. Drives the dossier.
        var selectedStar: Star?
        /// The in-transit device whose ship icon was tapped; nil when none. Drives
        /// the ship dossier, and is mutually exclusive with `selectedStar` (picking
        /// one clears the other) so only one HUD dossier shows at a time.
        var selectedShipDeviceCode: String?
        /// The orrery location designation picked in a system/body view (planet, moon,
        /// belt, Lagrange point, structure, or the star); nil when none. Drives the
        /// location dossier. Mutually exclusive with the other selections, and cleared
        /// on any level change (drill/zoom) since anchors are level-specific.
        var selectedLocation: String?
        /// Label of the active data filter (nil = none). Drives the HUD chip.
        var activeFilterName: String?
        /// Toggled info overlays. Ported for the layer rail; not yet wired to the
        /// renderer (the rail is presentational for now).
        var activeLayers: Set<InfoLayer>
        /// Whether the camera slowly auto-rotates.
        var autoRotate: Bool
        /// Incremented to request a one-shot recenter on the current location.
        var cameraResetToken: Int
        /// Live text in the galaxy HUD's star-search field. Empty hides the
        /// results list; the view filters the charted catalog against it.
        var searchQuery: String
        /// Incremented to request a one-shot eased camera re-aim on `selectedStar`
        /// — the search's "navigate there" (mirrors `cameraResetToken`).
        var starFocusToken: Int
        /// Which scale the map shows — the whole galaxy, or one drilled-in system.
        var focus: StarMapFocus
        /// True while a drill-in / zoom-out camera fly is in progress.
        var isTransitioning: Bool
        /// A pending `travel` itinerary for the active replicant's host vessel,
        /// shown as a confirmation sheet before the command is dispatched — the
        /// same dry-run review the Devices inspector uses. Non-nil ⇒ presented.
        var travelPreview: TravelPreview?

        // Survey (nearby-stars fetch + persist) + the themed first-run rebuild.
        /// The active replicant whose nearby stars we survey, from the signed-in
        /// session's local selection. Nil until an account with a replicant signs in.
        @Shared(.appStorage(Account.activeReplicantCodeKey)) var activeReplicantCode: String?
        var isSurveying: Bool
        var surveyStarCount: Int
        var surveyError: String?
        var bootPhase: BootPhase
        /// When the next full survey is allowed, per the catalogue endpoint's own
        /// rate limit (nil = ready now). Non-nil disables the survey button until a
        /// timer clears it.
        var surveyCooldownUntil: Date?

        var isOnCooldown: Bool { surveyCooldownUntil != nil }

        public init() {
            self.selectedStar = nil
            self.selectedShipDeviceCode = nil
            self.selectedLocation = nil
            self.activeFilterName = nil
            self.activeLayers = [.presence]
            self.autoRotate = true
            self.cameraResetToken = 0
            self.searchQuery = ""
            self.starFocusToken = 0
            self.focus = .galaxy
            self.isTransitioning = false
            self.travelPreview = nil
            self.isSurveying = false
            self.surveyStarCount = 0
            self.surveyError = nil
            self.bootPhase = .idle
            self.surveyCooldownUntil = nil
        }
    }

    public enum Action {
        // Ship overlay: a device icon over a pip was tapped (surfaces its dossier),
        // the dossier was dismissed, or its "View device" was tapped (bubbles up so
        // the container opens that device's inspector).
        case shipSelected(String)        // device_code
        case shipDeselected
        case viewDeviceRequested(String) // device_code
        // Orrery location picking (system/body view): a location anchor was clicked.
        case locationSelected(String)    // location designation
        case delegate(Delegate)
        // Interaction outcomes forwarded from the Metal input layer.
        case starFocused(Star?)          // single-click re-aim resolved to this star
        case starDived(Star)             // double-click dive resolved to this star
        case selectionCleared            // esc
        case homeRequested               // H
        case dataFilterCycled(String?)   // F — new filter label (nil = off)
        // HUD controls.
        case layerToggled(InfoLayer)
        case autoRotateToggled
        case recenterTapped
        // Star search: query edits, and picking a result to fly to.
        case searchQueryChanged(String)
        case searchResultSelected(Star)
        // Drill-in / zoom-out across the galaxy → system → body scales.
        case drillInRequested(String)         // system designation
        case drillIntoBodyRequested(String)   // planet designation (from a system view)
        case zoomOutRequested                 // steps out one level
        case transitionCompleted
        // FTL mesh: the view fires this when the relay roster changes (and once on
        // appear); the reducer rebuilds and persists the mesh off each relay's
        // backend network view. The view then renders the persisted `FTLLinkRecord`
        // rows directly, so the drawn mesh survives relaunch and a failed read.
        case refreshMesh(rosterChanged: Bool)
        /// Full re-scan of the replicant's current system (the only source of HZ /
        /// outer-system / hazards); refreshes the persisted `SystemDetail`.
        case scanCurrentSystemTapped
        // Travel command preview flow, driven from the galaxy dossier's Travel
        // button: request a dry-run plan for the active replicant's host vessel,
        // receive it, then either confirm (dispatch for real) or dismiss the sheet.
        // Mirrors the Devices inspector's travel flow.
        case travelPreviewRequested(deviceCode: String, destination: String)
        case travelPreviewResponse(TravelPreviewOutcome)
        case travelPreviewConfirmed
        case travelPreviewDismissed
        // First-run survey / boot sequence.
        case task
        case firstRunSurveyStarted
        case surveyButtonTapped
        case catalogueLoaded(count: Int)
        case surveyFinished
        case surveyFailed(String)
        case surveyCooldownStarted(Date?)
        case cooldownElapsed
        case bootDismissed

        @CasePathable
        public enum Delegate: Equatable {
            /// The player asked to open a device's inspector from a ship dossier —
            /// the container switches to the Devices category and selects it.
            case openDevice(String)
        }
    }

    private enum CancelID { case survey, cooldown, transition, locationHydrate, travelPreview }

    /// The per-replicant exploration overlay walks pages at the server's `per_page`
    /// cap. Explored (nearest) systems cluster in the first pages, so the walk
    /// stops as soon as a page carries none.
    static let overlayPageSize = 100

    /// Fly durations, in ms. Must match the camera eases in `StarFieldRenderer`.
    static let drillInBaseMs = 1150
    static let zoomOutBaseMs = 950

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.starsClient) var starsClient
    @Dependency(\.locationsClient) var locationsClient
    @Dependency(\.domainFreshness) var domainFreshness
    @Dependency(\.commandClient) var commandClient
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .shipSelected(code):
                // Surfacing a ship dossier takes over the shared HUD slot from any
                // system/location dossier.
                state.selectedShipDeviceCode = code
                state.selectedStar = nil
                state.selectedLocation = nil
                return .none

            case .shipDeselected:
                state.selectedShipDeviceCode = nil
                return .none

            case let .viewDeviceRequested(code):
                return .send(.delegate(.openDevice(code)))

            case let .locationSelected(code):
                // Picking an orrery location takes over the shared HUD dossier slot.
                state.selectedLocation = code
                state.selectedStar = nil
                state.selectedShipDeviceCode = nil
                // Best-effort: pull this location's live detail and merge it — other
                // players' devices at belts/Lagrange/structures aren't in the system-scan
                // blob (only per-location detail carries them). The `@Fetch` then refreshes
                // the clusters + dossier. Skip the bare system/star (nothing extra to fetch).
                let system = String(code.split(separator: "-").first ?? "")
                guard !system.isEmpty, system != code else { return .none }
                let client = locationsClient
                return .run { _ in
                    try? await client.hydrateBody(systemDesignation: system, bodyDesignation: code)
                }
                .cancellable(id: CancelID.locationHydrate, cancelInFlight: true)

            case .delegate:
                return .none

            case let .starFocused(star):
                state.selectedStar = star
                state.selectedShipDeviceCode = nil
                state.selectedLocation = nil
                return .none

            case let .starDived(star):
                state.selectedStar = star
                state.selectedShipDeviceCode = nil
                state.selectedLocation = nil
                return .none

            case .selectionCleared, .homeRequested:
                state.selectedStar = nil
                state.selectedShipDeviceCode = nil
                state.selectedLocation = nil
                return .none

            case let .dataFilterCycled(name):
                state.activeFilterName = name
                return .none

            case let .layerToggled(layer):
                if state.activeLayers.contains(layer) {
                    state.activeLayers.remove(layer)
                } else {
                    state.activeLayers.insert(layer)
                }
                return .none

            case .autoRotateToggled:
                state.autoRotate.toggle()
                return .none

            case .recenterTapped:
                state.cameraResetToken += 1
                return .none

            case let .searchQueryChanged(text):
                state.searchQuery = text
                return .none

            case let .searchResultSelected(star):
                // Select it (surfaces the dossier) and request the camera fly.
                // The search UI only shows in the galaxy HUD, so focus is `.galaxy`.
                state.selectedStar = star
                state.selectedShipDeviceCode = nil
                state.selectedLocation = nil
                state.searchQuery = ""
                state.starFocusToken += 1
                return .none

            case let .drillInRequested(id):
                // Only from the galaxy, not mid-fly. The dossier only offers the
                // control for explored systems, so the reducer trusts it.
                guard !state.isTransitioning, state.focus == .galaxy else { return .none }
                state.focus = .system(id)
                state.selectedLocation = nil   // anchors are level-specific
                state.isTransitioning = true
                let clock = self.clock
                let transition: Effect<Action> = .run { send in
                    try await clock.sleep(for: .milliseconds(Self.drillInBaseMs))
                    await send(.transitionCompleted)
                }
                .cancellable(id: CancelID.transition)
                // Best-effort refresh of the system roster (GET locations) so the
                // orrery shows live planets/belts; the `@Fetch` picks it up.
                return .merge(transition, hydrateSystem(id))

            case let .drillIntoBodyRequested(bodyID):
                // Only from a system view, not mid-fly. Rows are only offered for a
                // scanned system, so the reducer trusts the affordance.
                guard !state.isTransitioning, case .system = state.focus else { return .none }
                state.focus = .body(bodyID)
                state.selectedLocation = nil   // anchors are level-specific
                state.isTransitioning = true
                let clock = self.clock
                let transition: Effect<Action> = .run { send in
                    try await clock.sleep(for: .milliseconds(Self.drillInBaseMs))
                    await send(.transitionCompleted)
                }
                .cancellable(id: CancelID.transition)
                // Fetch the body's moon roster (the scan only gives moon_count); the
                // `@Fetch` re-renders the body orrery when it merges. Deferred until the
                // fly lands: the hydrate's DB write triggers a re-render that re-decodes
                // the persisted `StarSystem` blob on the main thread — cheap at rest, but
                // mid-fly it stalls the render loop and drops frames. Landing first keeps
                // the drill silky; the moons pop in a beat later.
                let hydrate: Effect<Action> = .concatenate(
                    .run { _ in try await clock.sleep(for: .milliseconds(Self.drillInBaseMs)) },
                    hydrateBody(bodyID)
                )
                return .merge(transition, hydrate)

            case .zoomOutRequested:
                // Steps out exactly one level: body → system → galaxy.
                guard !state.isTransitioning else { return .none }
                state.selectedLocation = nil   // anchors are level-specific
                switch state.focus {
                case .galaxy:
                    return .none
                case .system:
                    state.focus = .galaxy
                case .body:
                    guard let parent = state.focus.systemDesignation else { return .none }
                    state.focus = .system(parent)
                }
                state.isTransitioning = true
                let clock = self.clock
                return .run { send in
                    try await clock.sleep(for: .milliseconds(Self.zoomOutBaseMs))
                    await send(.transitionCompleted)
                }
                .cancellable(id: CancelID.transition)

            case .transitionCompleted:
                state.isTransitioning = false
                return .none

            case let .refreshMesh(rosterChanged):
                // The mesh rebuild is O(relays) network reads, so it goes through
                // the freshness engine instead of firing directly (V3.4-B2/B6). A
                // genuine roster change invalidates — the debounce collapses the
                // cold-load's page-by-page roster churn into one rebuild. A mere
                // pane appear only rebuilds when the domain is stale or its TTL
                // lapsed; the `relay.*` event route keeps it fresh in between.
                let domainFreshness = self.domainFreshness
                if rosterChanged {
                    return .run { _ in domainFreshness.invalidate(.ftlMesh) }
                }
                return .run { _ in await domainFreshness.refreshIfStale(.ftlMesh) }

            case .scanCurrentSystemTapped:
                guard let code = state.activeReplicantCode, !code.isEmpty else { return .none }
                let client = locationsClient
                return .run { _ in try? await client.scanAndPersist(replicantCode: code) }

            case let .travelPreviewRequested(deviceCode, destination):
                state.travelPreview = TravelPreview(deviceCode: deviceCode, destination: destination)
                let commandClient = self.commandClient
                return .run { send in
                    await send(.travelPreviewResponse(commandClient.previewTravel(deviceCode, destination)))
                }
                // A new preview cancels any prior in-flight dry-run so a late
                // response can't overwrite this one's phase.
                .cancellable(id: CancelID.travelPreview, cancelInFlight: true)

            case let .travelPreviewResponse(outcome):
                // Ignore a late response if the user already dismissed the sheet.
                guard state.travelPreview != nil else { return .none }
                switch outcome {
                case let .plan(plan):
                    state.travelPreview?.phase = .loaded(plan)
                case let .rejected(message), let .failed(message):
                    state.travelPreview?.phase = .failed(message)
                }
                return .none

            case .travelPreviewConfirmed:
                guard let preview = state.travelPreview else { return .none }
                state.travelPreview = nil
                let commandClient = self.commandClient
                let deviceCode = preview.deviceCode
                let destination = preview.destination
                // The dispatched op surfaces via table observation (GameSync +
                // reconciler drive it to completion); the map never inspects the
                // response, matching the Devices inspector's fire-and-forget.
                return .run { _ in
                    _ = await commandClient.dispatch(.travel, deviceCode, CommandParams(destination: destination))
                }

            case .travelPreviewDismissed:
                state.travelPreview = nil
                return .cancel(id: CancelID.travelPreview)

            case .surveyButtonTapped:
                guard !state.isSurveying, !state.isOnCooldown else { return .none }
                return runSurvey(&state)

            case let .catalogueLoaded(count):
                state.surveyStarCount = count
                return .none

            case .surveyFinished:
                state.isSurveying = false
                if state.bootPhase == .rebuilding {
                    state.bootPhase = .complete
                    let clock = self.clock
                    return .run { send in
                        try await clock.sleep(for: .milliseconds(1400))
                        await send(.bootDismissed)
                    }
                }
                return .none

            case let .surveyFailed(message):
                state.isSurveying = false
                state.surveyError = message
                // Dismiss the loading overlay; the HUD survey control surfaces the
                // message (and any cooldown) so the map is usable immediately.
                state.bootPhase = .idle
                return .none

            case let .surveyCooldownStarted(until):
                return setCooldown(&state, until: until)

            case .cooldownElapsed:
                state.surveyCooldownUntil = nil
                return .none

            case .task:
                // First run only: if the local star catalog is empty, load the full
                // catalogue up front (no themed gate — just fetch it).
                guard state.bootPhase == .idle, !state.isSurveying else { return .none }
                let database = self.database
                return .run { send in
                    let count = try await database.read { db in
                        try UniverseModels.Star.fetchCount(db)
                    }
                    if count == 0 { await send(.firstRunSurveyStarted) }
                } catch: { _, _ in }

            case .firstRunSurveyStarted:
                guard !state.isSurveying, !state.isOnCooldown else { return .none }
                state.bootPhase = .rebuilding
                return runSurvey(&state)

            case .bootDismissed:
                state.bootPhase = .idle
                return .none
            }
        }
    }

    /// Best-effort refresh of one system's roster (GET locations), merged onto any
    /// existing (possibly scanned) `SystemDetail` and re-persisted — the orrery's
    /// `@Fetch` then re-renders. Preserves richer per-body/scan detail via
    /// `mergingSystemDetail`. Silently no-ops for systems the server won't serve.
    private func hydrateSystem(_ designation: String) -> Effect<Action> {
        let client = locationsClient
        let database = self.database
        let date = self.date
        return .run { _ in
            // Nothing to persist (and no clock/db touched) unless the fetch lands.
            guard let fresh = try? await client.system(designation) else { return }
            try? await database.write { db in
                let existing = try SystemDetail
                    .where { $0.designation.eq(designation) }.fetchOne(db)
                let merged = (try existing?.system())?.mergingSystemDetail(fresh) ?? fresh
                let row = try SystemDetail(system: merged, hydratedAt: date.now)
                try SystemDetail.upsert { row }.execute(db)
            }
        }
    }

    /// Best-effort fetch of one body's detail (its moon roster + per-moon sites),
    /// merged into the persisted `SystemDetail` blob — the body orrery's `@Fetch`
    /// then re-renders with the moons. Silently no-ops for a system the server
    /// won't serve. The parent system is the body designation's prefix (`SYSTEM-n`).
    private func hydrateBody(_ bodyDesignation: String) -> Effect<Action> {
        let client = locationsClient
        let system = String(bodyDesignation.split(separator: "-").first ?? "")
        guard !system.isEmpty else { return .none }
        return .run { _ in
            try? await client.hydrateBody(systemDesignation: system, bodyDesignation: bodyDesignation)
        }
    }

    /// Runs the full survey: one non-paged download of the entire objective star
    /// catalogue (`GET /v1/stars`), then a bounded per-replicant pass that overlays
    /// `explored` / `has_life`. The view's `@FetchAll` observation renders the
    /// inserted rows. The catalogue endpoint is rate-limited to ≈one call a minute;
    /// on cooldown the download throws and we surface the reset (from its response
    /// headers) rather than an error, disabling the button until it lifts.
    private func runSurvey(_ state: inout State) -> Effect<Action> {
        guard let code = state.activeReplicantCode, !code.isEmpty else {
            state.surveyError = "No active replicant selected."
            state.bootPhase = .idle
            return .none
        }
        state.isSurveying = true
        state.surveyError = nil
        state.surveyStarCount = 0
        let starsClient = self.starsClient
        let database = self.database
        let date = self.date
        let overlayPageSize = Self.overlayPageSize
        return .run { send in
            // 1. Full objective catalogue in a single request.
            let catalogue: [StarItem]
            do {
                catalogue = try await starsClient.catalogue()
            } catch {
                let cooldown = await starsClient.cooldownUntil()
                let message = cooldown != nil
                    ? "Survey is on cooldown — try again shortly."
                    : error.localizedDescription
                await send(.surveyFailed(message))
                await send(.surveyCooldownStarted(cooldown))
                return
            }
            let stamp = date.now
            let records = catalogue.map { UniverseModels.Star(item: $0, createdAt: stamp) }
            try await database.write { db in
                try UniverseModels.Star.insert {
                    records
                } onConflict: {
                    $0.designation
                } doUpdate: { row, excluded in
                    // Objective catalogue fields refresh; per-replicant knowledge
                    // (explored/hasLife) and local lifecycle timestamps are
                    // preserved — the catalogue carries neither.
                    row.spectralType = excluded.spectralType
                    row.color = excluded.color
                    row.positionX = excluded.positionX
                    row.positionY = excluded.positionY
                    row.positionZ = excluded.positionZ
                    row.estimatedPlanets = excluded.estimatedPlanets
                    row.entryPoint = excluded.entryPoint
                }
                .execute(db)
            }
            await send(.catalogueLoaded(count: catalogue.count))

            // 2. Best-effort per-replicant exploration overlay. The listing is
            // distance-sorted and explored systems are the nearest, so they cluster
            // in the first pages; stop at the first page carrying none rather than
            // walking the whole ~140-page catalogue.
            do {
                for try await result in starsClient.survey(code, overlayPageSize) {
                    let explored = result.stars.filter(\.explored)
                    if !explored.isEmpty {
                        let records = explored.map { UniverseModels.Star(item: $0, createdAt: stamp) }
                        try await database.write { db in
                            try UniverseModels.Star.insert {
                                records
                            } onConflict: {
                                $0.designation
                            } doUpdate: { row, excluded in
                                row.explored = excluded.explored
                                row.hasLife = excluded.hasLife
                            }
                            .execute(db)
                        }
                    }
                    if explored.isEmpty { break }
                }
            } catch {
                // Enrichment is best-effort; the catalogue already loaded.
            }

            await send(.surveyFinished)
            await send(.surveyCooldownStarted(starsClient.cooldownUntil()))
        } catch: { error, send in
            await send(.surveyFailed(error.localizedDescription))
        }
        .cancellable(id: CancelID.survey)
    }

    /// Arms (or clears) the survey-button cooldown: holds `until` in state and
    /// schedules a one-shot to clear it the moment the window lifts, re-enabling
    /// the button without any polling. A nil or past date clears immediately.
    private func setCooldown(_ state: inout State, until: Date?) -> Effect<Action> {
        let now = self.date.now
        guard let until, until > now else {
            state.surveyCooldownUntil = nil
            return .cancel(id: CancelID.cooldown)
        }
        state.surveyCooldownUntil = until
        let clock = self.clock
        let interval = until.timeIntervalSince(now)
        return .run { send in
            try await clock.sleep(for: .seconds(interval))
            await send(.cooldownElapsed)
        }
        .cancellable(id: CancelID.cooldown, cancelInFlight: true)
    }
}
