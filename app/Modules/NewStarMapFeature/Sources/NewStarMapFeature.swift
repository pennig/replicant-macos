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
        var surveyPagesDone: Int
        var surveyTotalPages: Int?
        var surveyStarCount: Int
        var surveyError: String?
        var bootPhase: BootPhase

        var surveyFraction: Double {
            guard let total = surveyTotalPages, total > 0 else { return 0 }
            return min(1, Double(surveyPagesDone) / Double(total))
        }

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
            self.surveyPagesDone = 0
            self.surveyTotalPages = nil
            self.surveyStarCount = 0
            self.surveyError = nil
            self.bootPhase = .idle
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
        case refreshMesh
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
        case surveyButtonTapped
        case surveyProgress(pagesDone: Int, totalPages: Int, starCount: Int)
        case surveyFinished
        case surveyFailed(String)
        case bootCorruptionDetected
        case manualOverrideTapped
        case bootDismissed

        @CasePathable
        public enum Delegate: Equatable {
            /// The player asked to open a device's inspector from a ship dossier —
            /// the container switches to the Devices category and selects it.
            case openDevice(String)
        }
    }

    private enum CancelID { case survey, transition, meshRefresh }

    /// The server caps `per_page` at 50.
    static let surveyPageSize = 50

    /// Fly durations, in ms. Must match the camera eases in `StarFieldRenderer`.
    static let drillInBaseMs = 1150
    static let zoomOutBaseMs = 950

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.starsClient) var starsClient
    @Dependency(\.locationsClient) var locationsClient
    @Dependency(\.ftlMeshRefresher) var ftlMeshRefresher
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
                return .none

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

            case .refreshMesh:
                // Rebuild and persist the mesh off the current relay roster (read
                // from the Device table inside the refresher) and each relay's live
                // network view. An empty roster correctly persists an empty mesh.
                let refresher = ftlMeshRefresher
                return .run { _ in await refresher.refresh() }
                    .cancellable(id: CancelID.meshRefresh, cancelInFlight: true)

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
                return .none

            case .surveyButtonTapped:
                guard !state.isSurveying else { return .none }
                return runSurvey(&state)

            case let .surveyProgress(pagesDone, totalPages, starCount):
                state.surveyPagesDone = pagesDone
                state.surveyTotalPages = totalPages
                state.surveyStarCount = starCount
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
                // Drop back to the modal so the override can be retried.
                if state.bootPhase == .rebuilding { state.bootPhase = .corruptionDetected }
                return .none

            case .task:
                // First run only: if the local star catalog is empty, present the
                // (themed) corruption modal that gates the initial rebuild.
                guard state.bootPhase == .idle else { return .none }
                let database = self.database
                return .run { send in
                    let count = try await database.read { db in
                        try UniverseModels.Star.fetchCount(db)
                    }
                    if count == 0 { await send(.bootCorruptionDetected) }
                } catch: { _, _ in }

            case .bootCorruptionDetected:
                guard state.bootPhase == .idle else { return .none }
                state.bootPhase = .corruptionDetected
                return .none

            case .manualOverrideTapped:
                guard !state.isSurveying else { return .none }
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

    /// Starts the paged nearby-stars survey: resets progress, then walks every
    /// page — persisting each (timestamps preserved on re-survey) and reporting
    /// progress. The view's `@FetchAll` observation renders the inserted rows.
    ///
    /// Cheap re-survey short-circuit: the listing is distance-sorted with no
    /// delta cursor and stars carry no server timestamp, so there's no way to
    /// ask for "only the new ones" — new stars interleave anywhere in the ~200
    /// pages. But page 1 reports the server's `total_stars`; if the local
    /// `stars` table already holds at least that many, nothing new exists and we
    /// stop after page 1 instead of re-walking every page. An empty catalog
    /// (first run / rebuild) has a count of 0, so the initial survey always
    /// walks fully.
    private func runSurvey(_ state: inout State) -> Effect<Action> {
        guard let code = state.activeReplicantCode, !code.isEmpty else {
            state.surveyError = "No active replicant selected."
            if state.bootPhase == .rebuilding { state.bootPhase = .corruptionDetected }
            return .none
        }
        state.isSurveying = true
        state.surveyError = nil
        state.surveyPagesDone = 0
        state.surveyTotalPages = nil
        state.surveyStarCount = 0
        let starsClient = self.starsClient
        let database = self.database
        let date = self.date
        let pageSize = Self.surveyPageSize
        return .run { send in
            let existingCount = (try? await database.read { db in
                try UniverseModels.Star.fetchCount(db)
            }) ?? 0
            for try await result in starsClient.survey(code, pageSize) {
                let stamp = date.now
                let records = result.stars.map { UniverseModels.Star(item: $0, createdAt: stamp) }
                try await database.write { db in
                    try UniverseModels.Star.insert {
                        records
                    } onConflict: {
                        $0.designation
                    } doUpdate: { row, excluded in
                        // Schema fields refresh; local lifecycle timestamps
                        // (createdAt/firstVisitedAt/fullyScannedAt) are preserved.
                        row.spectralType = excluded.spectralType
                        row.color = excluded.color
                        row.positionX = excluded.positionX
                        row.positionY = excluded.positionY
                        row.positionZ = excluded.positionZ
                        row.estimatedPlanets = excluded.estimatedPlanets
                        row.explored = excluded.explored
                        row.hasLife = excluded.hasLife
                        row.entryPoint = excluded.entryPoint
                    }
                    .execute(db)
                }
                await send(.surveyProgress(
                    pagesDone: result.page,
                    totalPages: result.totalPages,
                    starCount: result.totalStars
                ))
                // Nothing new since the last survey — stop after page 1 rather
                // than re-walking every page. The next page is only requested on
                // the following loop turn, so breaking here costs one request.
                if result.page == 1, result.totalStars > 0, existingCount >= result.totalStars {
                    break
                }
            }
            await send(.surveyFinished)
        } catch: { error, send in
            await send(.surveyFailed(error.localizedDescription))
        }
        .cancellable(id: CancelID.survey)
    }
}
