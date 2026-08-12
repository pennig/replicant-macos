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
                .first { !$0.hasTag(HaulRun.defaultFleetTag) }
        }

        /// The row's required anchor device. Lowest code for determinism.
        public var anchorControllerCode: String? { readyControllers.first?.deviceCode }

        public var canLaunch: Bool { anchorControllerCode != nil }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
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

            case .launchTapped:
                guard let anchor = state.anchorControllerCode else { return .none }
                logger.info("launching haul run anchored on \(anchor, privacy: .public)")
                // Bound to locals: referencing the property wrappers inside the
                // @Sendable closure would capture the non-Sendable reducer.
                let database = self.database
                let dismiss = self.dismiss
                let id = uuid().uuidString
                let now = date.now
                return .run { send in
                    // `Brain.ensureHaul`'s own resolution — never the bare
                    // tag, which reserves the whole fleet account-wide.
                    let tag = (try? await database.read { db -> String in
                        let view = try WorldView.read(from: db, now: now)
                        guard let device = view.devices[anchor], let theatre = view.owningTheatre(of: device)
                        else { return HaulRun.defaultFleetTag }
                        return HaulRun.fleetTag(forTheatre: theatre.depot)
                    }) ?? HaulRun.defaultFleetTag
                    let directive = Directive(
                        id: id,
                        kind: .haulRun,
                        status: .running,
                        // Anchor only — see this file's header. The machine
                        // resolves its controllers by tag on every evaluation.
                        deviceCode: anchor,
                        // The engine claims nothing: a Haul Run drives EVERY
                        // tagged controller, so pinning one would misrepresent it.
                        controllerCode: nil,
                        // No roam centre: this run plans over locations, not
                        // systems, and never emits `.extendQueue`.
                        roamCentre: nil,
                        fleetTag: tag,
                        // Empty and stays empty — the planner re-derives every
                        // cycle from the footprint census, and records no history.
                        targets: [],
                        targetIndex: 0,
                        step: HaulRun().firstStep,
                        stepStartedAt: now,
                        returnToOrigin: false,
                        originDesignation: nil,
                        attentionReason: nil,
                        createdAt: now,
                        updatedAt: now
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
