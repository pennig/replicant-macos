//
//  NewHaulRunFeature.swift
//  Replicould — Directives feature
//
//  The Haul Run launcher. Unlike every other launcher there is nothing to pick:
//  the run drives EVERY controller tagged `auto:haul` (design spec §4), so this
//  dialog reports the fleet the tag resolves to and offers Launch.
//
//  `Directive.deviceCode` is a required column, so the lowest-coded tagged
//  controller anchors the row. The machine never reads it — it re-resolves its
//  working set by tag on every evaluation — so a fleet that grows or shrinks
//  under the run needs no edit to the row.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameModels
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Directives")

@Reducer
public struct NewHaulRunFeature {
    @ObservableState
    public struct State: Equatable {
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceCode }, animation: .default)
        public var devices: [Device]

        /// The depot the launch will stamp, once `task` has resolved it. Nil
        /// until then, and for an anchor no theatre owns.
        public var deliveryDepot: String?

        public init() {}

        /// A `WorldSnapshot` over the synced fleet, so eligibility is judged by
        /// `HaulRun`'s OWN query rather than a hand-rolled approximation of it.
        private var world: WorldSnapshot {
            WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: [:],
                now: Date(timeIntervalSince1970: 0)
            )
        }

        /// Controllers the run would actually drive: tagged, and offering `ferry`.
        public var readyControllers: [Device] {
            HaulRun.controllers(in: world, tag: HaulRun.defaultFleetTag)
        }

        /// A `ferry`-capable controller that is NOT tagged — named so the empty
        /// state can point at it specifically rather than saying "tag something".
        public var untaggedController: Device? {
            devices
                .filter { $0.availableDirectives.contains(HaulTargetPlanner.ferry) }
                .first { !$0.carries(HaulRun.defaultFleetTag, policy: .exact) }
        }

        /// The row's required anchor device. Lowest code for determinism.
        public var anchorControllerCode: String? { readyControllers.first?.deviceCode }

        public var canLaunch: Bool { anchorControllerCode != nil }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// Resolve the depot this launch would deliver to, for the summary.
        case task
        case deliveryDepotResolved(String?)
        case launchTapped
        case cancelTapped
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case created(Directive)
        }
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.uuid) var uuid

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                guard let anchor = state.anchorControllerCode else { return .none }
                let database = self.database
                let now = date.now
                return .run { send in
                    let theatre = await LauncherTheatre.resolve(
                        for: anchor, goal: .haul, database: database, now: now
                    )
                    await send(.deliveryDepotResolved(theatre?.depot))
                }

            case let .deliveryDepotResolved(depot):
                state.deliveryDepot = depot
                return .none

            case .launchTapped:
                guard let controller = state.readyControllers.first else { return .none }
                let anchor = controller.deviceCode
                logger.info("launching haul run anchored on \(anchor, privacy: .public)")
                // Bound to locals: referencing the property wrappers inside the
                // @Sendable closure would capture the non-Sendable reducer.
                let database = self.database
                let dismiss = self.dismiss
                let id = uuid().uuidString
                let now = date.now
                // Stamped even though the machine never reads it: without it
                // `Brain.adoptTheatres` can never rescue an unstamped row.
                let origin = controller.location.map { SiteAssay.system(of: $0) }
                return .run { send in
                    let theatre = await LauncherTheatre.resolve(
                        for: anchor, goal: .haul, database: database, now: now
                    )
                    let directive = Directive.launch(
                        .init(
                            kind: .haulRun,
                            // Anchor only — see this file's header. The machine
                            // resolves its controllers by tag every evaluation.
                            deviceCode: anchor,
                            theatre: theatre,
                            originDesignation: origin
                        ),
                        id: id, now: now
                    )
                    try? await database.write { db in
                        try Directive.insert { directive }.execute(db)
                    }
                    await send(.delegate(.created(directive)))
                    await dismiss()
                }

            case .cancelTapped:
                let dismissNow = self.dismiss
                return .run { _ in await dismissNow() }

            case .delegate:
                return .none
            }
        }
    }
}
