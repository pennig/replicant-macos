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
import SQLiteData
import UniverseModels

@Reducer
public struct NewStarMapFeature {
    @ObservableState
    public struct State: Equatable {
        /// The star surfaced by the last pick (single-click re-aim or double-click
        /// dive); nil after a clear/home. Drives the dossier.
        var selectedStar: Star?
        /// Label of the active data filter (nil = none). Drives the HUD chip.
        var activeFilterName: String?
        /// Toggled info overlays. Ported for the layer rail; not yet wired to the
        /// renderer (the rail is presentational for now).
        var activeLayers: Set<InfoLayer>
        /// Whether the camera slowly auto-rotates.
        var autoRotate: Bool
        /// Incremented to request a one-shot recenter on the current location.
        var cameraResetToken: Int
        /// Which scale the map shows — the whole galaxy, or one drilled-in system.
        var focus: StarMapFocus
        /// True while a drill-in / zoom-out camera fly is in progress.
        var isTransitioning: Bool
        /// Debug knob: multiplies the drill/zoom animation duration (1× = normal,
        /// higher = slower) so the transition can be reviewed in slow motion.
        var transitionDurationScale: Double

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
            self.activeFilterName = nil
            self.activeLayers = [.presence]
            self.autoRotate = true
            self.cameraResetToken = 0
            self.focus = .galaxy
            self.isTransitioning = false
            self.transitionDurationScale = 1
            self.isSurveying = false
            self.surveyPagesDone = 0
            self.surveyTotalPages = nil
            self.surveyStarCount = 0
            self.surveyError = nil
            self.bootPhase = .idle
        }
    }

    public enum Action {
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
        // Drill-in / zoom-out between the galaxy and a single system's orrery.
        case drillInRequested(String)   // system designation
        case zoomOutRequested
        case transitionCompleted
        case transitionDurationScaleChanged(Double)
        // First-run survey / boot sequence.
        case task
        case surveyButtonTapped
        case surveyProgress(pagesDone: Int, totalPages: Int, starCount: Int)
        case surveyFinished
        case surveyFailed(String)
        case bootCorruptionDetected
        case manualOverrideTapped
        case bootDismissed
    }

    private enum CancelID { case survey, transition }

    /// The server caps `per_page` at 50.
    static let surveyPageSize = 50

    /// Base fly durations, in ms (scaled by `transitionDurationScale`). Must match
    /// the camera eases in `StarFieldRenderer`.
    static let drillInBaseMs = 1150
    static let zoomOutBaseMs = 950

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.starsClient) var starsClient
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .starFocused(star):
                state.selectedStar = star
                return .none

            case let .starDived(star):
                state.selectedStar = star
                return .none

            case .selectionCleared, .homeRequested:
                state.selectedStar = nil
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

            case let .drillInRequested(id):
                // Only from the galaxy, not mid-fly. The dossier only offers the
                // control for explored systems, so the reducer trusts it.
                guard !state.isTransitioning, state.focus == .galaxy else { return .none }
                state.focus = .system(id)
                state.isTransitioning = true
                let clock = self.clock
                let ms = Int(Double(Self.drillInBaseMs) * state.transitionDurationScale)
                return .run { send in
                    try await clock.sleep(for: .milliseconds(ms))
                    await send(.transitionCompleted)
                }
                .cancellable(id: CancelID.transition)

            case .zoomOutRequested:
                guard !state.isTransitioning, case .system = state.focus else { return .none }
                state.focus = .galaxy
                state.isTransitioning = true
                let clock = self.clock
                let ms = Int(Double(Self.zoomOutBaseMs) * state.transitionDurationScale)
                return .run { send in
                    try await clock.sleep(for: .milliseconds(ms))
                    await send(.transitionCompleted)
                }
                .cancellable(id: CancelID.transition)

            case .transitionCompleted:
                state.isTransitioning = false
                return .none

            case let .transitionDurationScaleChanged(scale):
                state.transitionDurationScale = scale
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

    /// Starts the paged nearby-stars survey: resets progress, then walks every
    /// page — persisting each (timestamps preserved on re-survey) and reporting
    /// progress. The view's `@FetchAll` observation renders the inserted rows.
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
            }
            await send(.surveyFinished)
        } catch: { error, send in
            await send(.surveyFailed(error.localizedDescription))
        }
        .cancellable(id: CancelID.survey)
    }
}
