//
//  NewSalvageRunFeature.swift
//  Replicould — Directives feature
//
//  The Salvage Run launcher: pick a staged vessel, go. There is no fixed-queue
//  variant to offer — a Salvage Run is always continuous (design spec §5), so
//  unlike `NewDirectiveFeature` this dialog has exactly one input.
//
//  Only properly STAGED vessels are offered, and eligibility is computed
//  through `SalvageRun`'s OWN fleet queries (`controller(aboard:in:)` +
//  `adoptedDrones(of:aboard:in:)`, both forwarding to the shared `AMIFleet`
//  helpers) — the same two preconditions `SalvageRun.preflight` hard-stalls
//  on. That is what makes it structurally impossible for this dialog to
//  create a run that stalls on its very first evaluation.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameModels
import OSLog
import SQLiteData
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Directives")

@Reducer
public struct NewSalvageRunFeature {
    @ObservableState
    public struct State: Equatable {
        /// The fleet — eligibility is derived from it, so the picker can never
        /// offer a vessel the engine would immediately stall on.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceCode }, animation: .default)
        public var devices: [Device]

        public var vesselCode: String?

        public init(vesselCode: String? = nil) {
            self.vesselCode = vesselCode
        }

        /// Vessels carrying a mining controller with at least one adopted
        /// drone stowed aboard. Built through a `WorldSnapshot` so the rule is
        /// literally `SalvageRun`'s own — the same object the engine calls at
        /// preflight, not a hand-rolled approximation of it.
        public var eligibleVessels: [Device] {
            let world = WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: [:],
                now: Date(timeIntervalSince1970: 0)
            )
            return devices.filter { candidate in
                guard let controller = SalvageRun.controller(aboard: candidate, in: world) else {
                    return false
                }
                return !SalvageRun.adoptedDrones(of: controller, aboard: candidate, in: world).isEmpty
            }
        }

        /// The chosen vessel's current system — a Salvage Run's roam centre,
        /// and the reason Launch stays disabled for a vessel whose location is
        /// unknown (stowed or in transit): `.extendQueue` needs SOME
        /// designation to anchor its first census read.
        public var anchorSystem: String? {
            guard let vesselCode,
                  let vessel = devices.first(where: { $0.deviceCode == vesselCode }),
                  let location = vessel.location
            else { return nil }
            return SiteAssay.system(of: location)
        }

        public var canLaunch: Bool { anchorSystem != nil }
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
                guard let vesselCode = state.vesselCode, let centre = state.anchorSystem,
                      let vessel = state.devices.first(where: { $0.deviceCode == vesselCode })
                else { return .none }
                let directive = Directive(
                    id: uuid().uuidString,
                    kind: .salvageRun,
                    status: .running,
                    deviceCode: vesselCode,
                    // The engine claims the controller at preflight, from
                    // whatever is actually aboard when the run starts —
                    // recording it here would go stale if the fleet moved
                    // meanwhile.
                    controllerCode: nil,
                    // Always set: a Salvage Run has no finish line, so this is
                    // what makes `.extendQueue` fire instead of `.done`.
                    roamCentre: centre,
                    // The run resolves its whole fleet by tag (spec §4.2) —
                    // vessel, controller, drones, and relays must all carry
                    // it, or `.refreshFleet` cannot see them.
                    fleetTag: SalvageRun.defaultFleetTag,
                    // Empty on purpose: the engine plans the first target from
                    // the catalogue on its first evaluation, via
                    // `SalvageTargetPlanner`. Pre-picking one here would
                    // duplicate that logic and could disagree with it.
                    targets: [],
                    targetIndex: 0,
                    step: SalvageRun().firstStep,
                    stepStartedAt: date.now,
                    // A continuous run has no queue to empty, so a return leg
                    // would never fire; keep the column honest rather than
                    // recording an intent that cannot happen.
                    returnToOrigin: false,
                    originDesignation: vessel.location.map { SiteAssay.system(of: $0) },
                    attentionReason: nil,
                    createdAt: date.now,
                    updatedAt: date.now
                )
                logger.info("launching salvage run \(directive.id, privacy: .public) on \(vesselCode, privacy: .public) centred on \(centre, privacy: .public)")
                // Bound to locals: referencing the property wrappers inside the
                // @Sendable closure would capture the non-Sendable reducer.
                let database = self.database
                let dismiss = self.dismiss
                return .run { send in
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
