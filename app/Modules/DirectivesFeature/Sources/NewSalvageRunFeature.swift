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
//  Physically staged is not the whole story, though: the run resolves its
//  entire fleet by the `auto:salvage` TAG (design spec §4.2), and `Device.tags`
//  is a real, locally-synced column (populated by the same mapper that backs
//  every fleet-wide fetch, and round-tripped through the device inspector's
//  own tag edits). So the picker can and does tell "staged and tagged" apart
//  from "staged but never tagged" at no extra cost — see `readyVessels` vs.
//  `eligibleVessels`/`untaggedStagedVessel` below — rather than leaving that
//  distinction to prose in an empty-state message.
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

        /// A `WorldSnapshot` over the currently-synced fleet — shared by every
        /// computed property below so they all judge the SAME read.
        private var world: WorldSnapshot {
            WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: [:],
                now: Date(timeIntervalSince1970: 0)
            )
        }

        /// Vessels carrying a mining controller with at least one adopted
        /// drone stowed aboard. Built through a `WorldSnapshot` so the rule is
        /// literally `SalvageRun`'s own — the same object the engine calls at
        /// preflight, not a hand-rolled approximation of it.
        ///
        /// This does NOT check tag membership — see `readyVessels` for the
        /// set that also does. Kept separate because `SalvageRun.controller`/
        /// `adoptedDrones` themselves don't filter by tag either (they read
        /// stow/adoption columns), so "physically staged" and "tagged" are
        /// genuinely two different questions with two different answers.
        public var eligibleVessels: [Device] {
            let world = self.world
            return devices.filter { candidate in
                guard let controller = SalvageRun.controller(aboard: candidate, in: world) else {
                    return false
                }
                return !SalvageRun.adoptedDrones(of: controller, aboard: candidate, in: world).isEmpty
            }
        }

        /// Physically-staged vessels whose WHOLE relevant fleet — the vessel
        /// itself, its controller, every drone the controller has adopted
        /// aboard it, and any FTL relay aboard — carries `auto:salvage`.
        ///
        /// `SalvageRun` resolves its entire fleet by this one tag (design
        /// spec §4.2): `.refreshFleet` calls `GET devices/tags/{tag}`, and a
        /// device physically staged but missing the tag simply never comes
        /// back from that read, however stale its local row gets. So this,
        /// not `eligibleVessels`, is the set that can actually be launched
        /// without risking a stall the moment the engine needs an
        /// authoritative re-read. The picker offers only this set.
        public var readyVessels: [Device] {
            let world = self.world
            return eligibleVessels.filter { isFullyTagged($0, in: world) }
        }

        /// A physically-staged vessel whose fleet is missing the tag
        /// somewhere — named so the empty state can point at IT specifically
        /// rather than a generic "some vessel needs a tag." Only meant to be
        /// consulted when `readyVessels` is empty; see `NewSalvageRunSheet`.
        public var untaggedStagedVessel: Device? {
            let world = self.world
            return eligibleVessels.first { !isFullyTagged($0, in: world) }
        }

        /// Whether `vessel`'s whole relevant fleet carries `auto:salvage`.
        /// Gates on the FULL set the run depends on, not the vessel alone:
        /// `SalvageRun`'s own doc comments (see `SalvageRun.swift`) list the
        /// vessel, controller, drones, AND relay as needing the tag, and a
        /// gap on any one of them is exactly as blinding to `.refreshFleet`
        /// as a gap on the vessel. A relay is checked only when one is
        /// actually aboard — it isn't required for eligibility (a vessel
        /// with none still routes through `restocking`), so its absence here
        /// must not read as a tagging problem.
        private func isFullyTagged(_ vessel: Device, in world: WorldSnapshot) -> Bool {
            guard let controller = SalvageRun.controller(aboard: vessel, in: world) else { return false }
            let drones = SalvageRun.adoptedDrones(of: controller, aboard: vessel, in: world)
            var fleet = [vessel, controller] + drones
            if let relay = SalvageRun.relay(aboard: vessel, in: world) { fleet.append(relay) }
            return fleet.allSatisfy { $0.carries(SalvageRun.defaultFleetTag, policy: .exact) }
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
                logger.info("launching salvage run on \(vesselCode, privacy: .public) centred on \(centre, privacy: .public)")
                // Bound to locals: referencing the property wrappers inside the
                // @Sendable closure would capture the non-Sendable reducer.
                let database = self.database
                let dismiss = self.dismiss
                let id = uuid().uuidString
                let now = date.now
                let origin = vessel.location.map { SiteAssay.system(of: $0) }
                return .run { send in
                    // `Brain.ensureSalvage`'s own resolution — never the bare
                    // tag (see `launcher-tag-resolution-error-narrowing.md`).
                    let tag: FleetTag
                    do {
                        tag = try await database.read { db -> FleetTag in
                            let view = try WorldView.read(from: db, now: now)
                            guard let device = view.devices[vesselCode], let theatre = view.owningTheatre(of: device, goal: .salvage)
                            else {
                                logger.notice("salvage launch on \(vesselCode, privacy: .public): no theatre resolves — bare tag")
                                return SalvageRun.defaultFleetTag
                            }
                            return SalvageRun.fleetTag(forTheatre: theatre.depot)
                        }
                    } catch {
                        logger.error("salvage launch on \(vesselCode, privacy: .public): theatre read failed: \(error) — bare tag")
                        tag = SalvageRun.defaultFleetTag
                    }
                    let directive = Directive(
                        id: id,
                        kind: .salvageRun,
                        status: .running,
                        deviceCode: vesselCode,
                        // Claimed at preflight from whatever is aboard then —
                        // recording it here would go stale if the fleet moved.
                        controllerCode: nil,
                        // Always set: with no finish line, this is what makes
                        // `.extendQueue` fire instead of `.done`.
                        roamCentre: centre,
                        // The run resolves its whole fleet by tag (spec §4.2) —
                        // `.refreshFleet` cannot see an untagged member.
                        fleetTag: tag.string,
                        // Empty: the engine plans the first target itself, via
                        // `SalvageTargetPlanner`, on its first evaluation.
                        targets: [],
                        targetIndex: 0,
                        step: SalvageRun().firstStep,
                        stepStartedAt: now,
                        // No queue to empty, so a return leg would never fire.
                        returnToOrigin: false,
                        originDesignation: origin,
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
