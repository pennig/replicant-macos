//
//  NewDirectiveFeature.swift
//  Replicould — Directives feature
//
//  The three-click launcher for a custom mission: pick a staged vessel, build a
//  target queue, go. Survey Run only in v1 (Relay Run lands with Stage 5).
//
//  Only properly STAGED vessels are offered. A Survey Run uses an AMI survey
//  controller already stowed aboard with at least one adopted drone stowed
//  alongside it — the engine validates exactly that at preflight and stalls
//  otherwise, so offering an unstaged vessel here would only manufacture a
//  stall. Eligibility is computed with `SurveyRun`'s own fleet queries, so there
//  is one definition of "staged" shared between the picker and the engine.
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
public struct NewDirectiveFeature {
    @ObservableState
    public struct State: Equatable {
        /// The fleet — eligibility is derived from it, so the picker can never
        /// offer a vessel the engine would immediately stall on.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceCode }, animation: .default)
        public var devices: [Device]

        /// The star census, for the target search.
        @ObservationStateIgnored
        @FetchAll(Star.order { $0.designation }, animation: .default)
        public var stars: [Star]

        public var vesselCode: String?
        /// The ordered target queue. Duplicates are legal by design (a revisit
        /// is a real thing to want); the picker just doesn't create them by
        /// accident.
        public var targets: [String] = []
        public var search: String = ""
        public var returnToOrigin = false

        /// Whether the run picks its own targets forever, or works a queue the
        /// user built.
        public enum Mode: String, CaseIterable, Equatable, Sendable {
            case continuous
            case fixedQueue

            public var title: String {
                switch self {
                case .continuous: "Continuous"
                case .fixedQueue: "Fixed queue"
                }
            }
        }

        /// Continuous by default: picking targets by hand is the thing this mode
        /// exists to remove, and switching back is one click.
        public var mode: Mode = .continuous

        /// An explicitly chosen centre. Nil means "use the vessel's own system",
        /// which is what `effectiveCentre` resolves.
        public var roamCentre: String?

        public init(vesselCode: String? = nil) {
            self.vesselCode = vesselCode
        }

        /// Vessels carrying a survey controller with at least one adopted drone
        /// stowed aboard. Built through a `WorldSnapshot` so the rule is
        /// literally the engine's.
        public var eligibleVessels: [Device] {
            let world = WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: [:],
                now: Date(timeIntervalSince1970: 0)
            )
            return devices.filter { candidate in
                guard let controller = SurveyRun.controller(aboard: candidate, in: world) else {
                    return false
                }
                return !SurveyRun.adoptedDrones(of: controller, aboard: candidate, in: world).isEmpty
            }
        }

        public var canLaunch: Bool {
            guard vesselCode != nil else { return false }
            switch mode {
            // A continuous run has nothing to queue — the centre IS the input.
            case .continuous: return effectiveCentre != nil
            case .fixedQueue: return !targets.isEmpty
            }
        }

        /// The system the chosen vessel is in — the point every suggested
        /// distance is measured from.
        ///
        /// Nil covers both "no vessel picked yet" and "vessel in transit or
        /// stowed" (`location == nil`), and the dialog offers no suggestions in
        /// either case. That matches the row it would write: `originDesignation`
        /// is already nil for a locationless vessel.
        public var anchorSystem: String? {
            guard let vesselCode,
                  let vessel = devices.first(where: { $0.deviceCode == vesselCode }),
                  let location = vessel.location
            else { return nil }
            return SiteAssay.system(of: location)
        }

        /// The centre a continuous run would actually use: an explicit pick, or
        /// the vessel's current system. Nil only when no vessel is chosen or it
        /// has no location — the same two cases `anchorSystem` covers, and the
        /// reason Launch is disabled for them.
        public var effectiveCentre: String? { roamCentre ?? anchorSystem }

        /// The five nearest systems still worth surveying, measured from the
        /// vessel. Always anchored on the vessel and never re-based onto the
        /// queue, so adding one removes it and pulls in the next-nearest instead
        /// of reshuffling the list.
        public var suggestedTargets: [SurveyTargetSuggestions.Suggestion] {
            guard let anchorSystem,
                  let anchor = stars.first(where: { $0.designation == anchorSystem })
            else { return [] }
            return SurveyTargetSuggestions.nearest(
                to: anchor.position,
                anchorDesignation: anchorSystem,
                stars: stars,
                excluding: Set(targets)
            )
        }

        /// Search hits, minus what is already queued. Capped because the census
        /// runs to thousands of stars and this is a picker, not a catalogue.
        public var searchResults: [Star] {
            let query = search.trimmingCharacters(in: .whitespaces).uppercased()
            guard !query.isEmpty else { return [] }
            let queued = Set(targets)
            return stars
                .filter { $0.designation.uppercased().hasPrefix(query) && !queued.contains($0.designation) }
                .prefix(50)
                .map { $0 }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case targetAdded(String)
        case targetRemoved(Int)
        case centrePicked(String)
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

            case let .targetAdded(designation):
                guard !state.targets.contains(designation) else { return .none }
                state.targets.append(designation)
                state.search = ""
                return .none

            case let .targetRemoved(index):
                guard state.targets.indices.contains(index) else { return .none }
                state.targets.remove(at: index)
                return .none

            case let .centrePicked(designation):
                state.roamCentre = designation
                state.search = ""
                return .none

            case .launchTapped:
                guard let vesselCode = state.vesselCode, state.canLaunch,
                      let vessel = state.devices.first(where: { $0.deviceCode == vesselCode })
                else { return .none }
                let isContinuous = state.mode == .continuous
                logger.info("launching \(isContinuous ? "continuous" : "fixed", privacy: .public) survey run on \(vesselCode, privacy: .public)")
                // Bound to locals: referencing the property wrappers inside the
                // @Sendable closure would capture the non-Sendable reducer.
                let database = self.database
                let dismiss = self.dismiss
                let id = uuid().uuidString
                let now = date.now
                let roamCentre = isContinuous ? state.effectiveCentre : nil
                let targets = isContinuous ? [] : state.targets
                let returnToOrigin = isContinuous ? false : state.returnToOrigin
                let origin = vessel.location.map { SiteAssay.system(of: $0) }
                return .run { send in
                    // `Brain.ensureSurvey`'s own resolution — never nil, which
                    // leaves `reservedDevices` skipping its sweep entirely.
                    let tag = (try? await database.read { db -> String in
                        let view = try WorldView.read(from: db, now: now)
                        guard let device = view.devices[vesselCode], let theatre = view.owningTheatre(of: device)
                        else { return SurveyRun.defaultFleetTag }
                        return SurveyRun.fleetTag(forTheatre: theatre.depot)
                    }) ?? SurveyRun.defaultFleetTag
                    let directive = Directive(
                        id: id,
                        kind: .surveyRun,
                        status: .running,
                        deviceCode: vesselCode,
                        // Claimed at preflight from whatever is aboard then —
                        // recording it here would go stale if the fleet moved.
                        controllerCode: nil,
                        // Non-nil is what makes the engine extend the queue
                        // rather than finish when it empties.
                        roamCentre: roamCentre,
                        fleetTag: tag,
                        // Empty on purpose: the engine plans the first target
                        // from the census on its first evaluation.
                        targets: targets,
                        targetIndex: 0,
                        step: SurveyRun().firstStep,
                        stepStartedAt: now,
                        // No queue to empty, so a return leg would never fire.
                        returnToOrigin: returnToOrigin,
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
