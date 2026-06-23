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
import Foundation

@Reducer
public struct StarMapFeature {
    @ObservableState
    public struct State: Equatable {
        public var systems: IdentifiedArrayOf<GalaxySystem>
        public var relays: [RelayLink]
        public var selectedSystemID: String?
        public var activeLayers: Set<InfoLayer>
        public var autoRotate: Bool
        /// Incremented to request a one-shot camera recenter (imperative command
        /// modeled declaratively so the representable can react to it).
        public var cameraResetToken: Int
        /// Which scale the map is showing, and whether a fly is in progress.
        public var focus: StarMapFocus
        public var isTransitioning: Bool

        /// The currently selected system, if any — drives the HUD dossier.
        public var selectedSystem: GalaxySystem? {
            guard let id = selectedSystemID else { return nil }
            return systems[id: id]
        }

        /// The drilled-in system, if any — drives the system HUD.
        public var focusedSystem: GalaxySystem? {
            guard case let .system(id) = focus else { return nil }
            return systems[id: id]
        }

        public init(
            systems: IdentifiedArrayOf<GalaxySystem> = IdentifiedArrayOf(uniqueElements: GalaxyData.systems),
            relays: [RelayLink] = GalaxyData.relays,
            selectedSystemID: String? = nil,
            activeLayers: Set<InfoLayer> = [.presence],
            autoRotate: Bool = true,
            cameraResetToken: Int = 0,
            focus: StarMapFocus = .galaxy,
            isTransitioning: Bool = false
        ) {
            self.systems = systems
            self.relays = relays
            self.selectedSystemID = selectedSystemID
            self.activeLayers = activeLayers
            self.autoRotate = autoRotate
            self.cameraResetToken = cameraResetToken
            self.focus = focus
            self.isTransitioning = isTransitioning
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
    }

    private enum CancelID { case transition }

    /// Fly durations (must match the SceneKit animation in `GalaxyScene`).
    static let drillInDuration: Duration = .milliseconds(1150)
    static let zoomOutDuration: Duration = .milliseconds(950)

    @Dependency(\.continuousClock) var clock

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
                // Only explored systems can be drilled into, and not mid-fly.
                guard !state.isTransitioning,
                      state.focus == .galaxy,
                      state.systems[id: id]?.star.explored == true
                else { return .none }
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
            }
        }
    }
}
