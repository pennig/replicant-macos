//
//  StarMapFeature.swift
//  StarMapFeature
//
//  The Galaxy Explorer reducer. It owns only declarative intent/UI state —
//  selection, the active info-layer set, auto-rotate, and a camera-reset nonce.
//  The retained scene graph, camera pose, and animations live in `GalaxyScene`
//  (an imperative @MainActor controller) behind the SwiftUI representable.
//

import ComposableArchitecture
import DependencyClients
import Foundation
import SQLiteData
import UniverseModels

@Reducer
public struct StarMapFeature {
    @ObservableState
    public struct State: Equatable {
        // The charted galaxy is rendered straight from the SQLite `Star` table
        // (observed in the view via `@FetchAll`); the reducer keeps only intent
        // and transient UI state.
        public var selectedSystemID: String?
        public var activeLayers: Set<InfoLayer>
        public var autoRotate: Bool
        /// Incremented to request a one-shot camera recenter (imperative command
        /// modeled declaratively so the representable can react to it).
        public var cameraResetToken: Int
        /// Which scale the map is showing, and whether a fly is in progress.
        public var focus: StarMapFocus
        public var isTransitioning: Bool

        // Survey (nearby-stars fetch + persist).
        /// The active replicant whose nearby stars we survey, sourced from the
        /// signed-in session's local selection (set on login by `AccountManager`).
        /// Nil until an account with a replicant is signed in.
        @Shared(.appStorage(Account.activeReplicantCodeKey)) public var activeReplicantCode: String?
        public var isSurveying: Bool
        public var surveyPagesDone: Int
        public var surveyTotalPages: Int?
        public var surveyStarCount: Int
        public var surveyError: String?
        /// The themed first-run database-rebuild sequence.
        public var bootPhase: BootPhase

        public var surveyFraction: Double {
            guard let total = surveyTotalPages, total > 0 else { return 0 }
            return min(1, Double(surveyPagesDone) / Double(total))
        }

        public init(
            selectedSystemID: String? = nil,
            activeLayers: Set<InfoLayer> = [.presence],
            autoRotate: Bool = true,
            cameraResetToken: Int = 0,
            focus: StarMapFocus = .galaxy,
            isTransitioning: Bool = false
        ) {
            self.selectedSystemID = selectedSystemID
            self.activeLayers = activeLayers
            self.autoRotate = autoRotate
            self.cameraResetToken = cameraResetToken
            self.focus = focus
            self.isTransitioning = isTransitioning
            self.isSurveying = false
            self.surveyPagesDone = 0
            self.surveyTotalPages = nil
            self.surveyStarCount = 0
            self.surveyError = nil
            self.bootPhase = .idle
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case systemTapped(String?)
        case layerToggled(InfoLayer)
        case autoRotateToggled
        case recenterTapped
        case drillInRequested(String)
        case zoomOutRequested
        case transitionCompleted
        case surveyButtonTapped
        case surveyProgress(pagesDone: Int, totalPages: Int, starCount: Int)
        case surveyFinished
        case surveyFailed(String)
        // First-run database-rebuild sequence.
        case task
        case bootCorruptionDetected
        case manualOverrideTapped
        case bootDismissed
    }

    private enum CancelID { case transition, survey }

    /// Fly durations (must match the SceneKit animation in `GalaxyScene`).
    static let drillInDuration: Duration = .milliseconds(1150)
    static let zoomOutDuration: Duration = .milliseconds(950)

    /// The server caps `per_page` at 50.
    static let surveyPageSize = 50

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.starsClient) var starsClient
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case let .systemTapped(id):
                state.selectedSystemID = id
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
                // Not mid-fly, and only from the galaxy. The view only offers the
                // drill control for explored systems, so the reducer trusts it.
                guard !state.isTransitioning, state.focus == .galaxy else { return .none }
                state.selectedSystemID = id
                state.focus = .system(id)
                state.isTransitioning = true
                let clock = self.clock
                return .run { send in
                    try await clock.sleep(for: Self.drillInDuration)
                    await send(.transitionCompleted)
                }
                .cancellable(id: CancelID.transition)

            case .zoomOutRequested:
                guard !state.isTransitioning, case .system = state.focus else { return .none }
                state.focus = .galaxy
                state.isTransitioning = true
                let clock = self.clock
                return .run { send in
                    try await clock.sleep(for: Self.zoomOutDuration)
                    await send(.transitionCompleted)
                }
                .cancellable(id: CancelID.transition)

            case .transitionCompleted:
                state.isTransitioning = false
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
                    let count = try await database.read { db in try Star.fetchCount(db) }
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
        // No survey is possible without an active replicant to survey around;
        // bail (and reopen the boot modal if this was the first-run rebuild).
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
                let records = result.stars.map { Star(item: $0, createdAt: stamp) }
                try await database.write { db in
                    try Star.insert {
                        records
                    } onConflict: {
                        $0.designation
                    } doUpdate: { row, excluded in
                        // Schema fields refresh; the local lifecycle timestamps
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
                // Persisting each page is enough — the view observes the `Star`
                // table via `@FetchAll`, so the scene renders the new rows
                // automatically. We only report counts for the modal's progress.
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
