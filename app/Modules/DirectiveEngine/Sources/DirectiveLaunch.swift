//
//  DirectiveLaunch.swift
//  Replicould — DirectiveEngine
//
//  The one constructor for a running mission row (spec S1.4).
//

import Foundation
import GameModels

extension Directive {
    /// What a launch SITE decides. What it cannot decide is the point: status,
    /// cursor, step, the three stamps, `theatreDepot` and `fleetTag` belong to
    /// `Directive.launch`, so no two sites can spell an invariant differently.
    public struct Launch: Sendable, Equatable {
        public var kind: DirectiveKind
        public var deviceCode: String
        /// Nil only when no theatre is operational: the row is then unstamped
        /// and its tag unscoped, which is the pre-theatre behaviour.
        public var theatre: Theatre?
        public var targets: [String]
        public var roamCentre: String?
        public var returnToOrigin: Bool
        public var originDesignation: String?
        public var controllerCode: String?
        /// Every cargo freighter the convoy leases, in load order. A convoy of
        /// one is a list of one; there is no singular form.
        public var freighterCodes: [String]
        public var sourceRelayCode: String?
        /// A mine ferry's belt. Scopes the tag to that BELT rather than the
        /// theatre; every other `.haulRun` leaves it nil.
        public var belt: String?
        /// The device a fetch run is collecting. Nil for every other kind.
        public var payloadCode: String?

        public init(
            kind: DirectiveKind,
            deviceCode: String,
            theatre: Theatre?,
            targets: [String] = [],
            roamCentre: String? = nil,
            returnToOrigin: Bool = false,
            originDesignation: String? = nil,
            controllerCode: String? = nil,
            freighterCodes: [String] = [],
            sourceRelayCode: String? = nil,
            belt: String? = nil,
            payloadCode: String? = nil
        ) {
            self.kind = kind
            self.deviceCode = deviceCode
            self.theatre = theatre
            self.targets = targets
            self.roamCentre = roamCentre
            self.returnToOrigin = returnToOrigin
            self.originDesignation = originDesignation
            self.controllerCode = controllerCode
            self.freighterCodes = freighterCodes
            self.sourceRelayCode = sourceRelayCode
            self.belt = belt
            self.payloadCode = payloadCode
        }
    }

    /// The row `launch` describes, at `now`. Every mission row in the app is
    /// built here.
    public static func launch(_ launch: Launch, id: String, now: Date) -> Directive {
        Directive(
            id: id,
            kind: launch.kind,
            status: .running,
            deviceCode: launch.deviceCode,
            controllerCode: launch.controllerCode,
            roamCentre: launch.roamCentre,
            fleetTag: fleetTag(for: launch)?.string,
            sourceRelayCode: launch.sourceRelayCode,
            targets: launch.targets,
            targetIndex: 0,
            step: MissionRegistry.firstStep(for: launch.kind),
            stepStartedAt: now,
            returnToOrigin: launch.returnToOrigin,
            originDesignation: launch.originDesignation,
            attentionReason: nil,
            createdAt: now,
            updatedAt: now,
            theatreDepot: launch.theatre?.depot,
            freighterCodes: launch.freighterCodes,
            payloadCode: launch.payloadCode
        )
    }

    /// The tag reserving this row's fleet, or nil for the kinds that reserve by
    /// device alone. A belt overrides the theatre scope — and keeps the `.mine`
    /// goal, which is what every mine-ferry query matches on.
    private static func fleetTag(for launch: Launch) -> FleetTag? {
        if launch.kind == .haulRun, let belt = launch.belt {
            // Per BELT: `reservedDevices` closes over a row's tag, so a
            // fleet-wide `.mine` would reserve every other mine's controller.
            return FleetTag(goal: .mine, scope: .belt(designation: belt))
        }
        guard let goal = fleetGoal(of: launch.kind) else { return nil }
        return FleetTag(goal: goal, scope: launch.theatre.map { .theatre(depot: $0.depot) })
    }

    private static func fleetGoal(of kind: DirectiveKind) -> FleetTag.Goal? {
        switch kind {
        case .surveyRun: .survey
        case .salvageRun: .salvage
        case .haulRun: .haul
        case .mineRun, .mineFleetPrint: .mine
        case .eventRun: .event
        // A fetch run reserves by device columns alone and writes no tag.
        case .relayRun, .restockRun, .eventCourierPrint, .fetchRun: nil
        }
    }
}
