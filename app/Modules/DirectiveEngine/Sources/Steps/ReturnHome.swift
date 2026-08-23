//
//  ReturnHome.swift
//  Replicould — DirectiveEngine
//
//  The trip back: resolve the destination, then fly whichever hull still
//  needs moving. One hull per evaluation, like every other dispatch.
//

import Foundation
import GameModels
import UniverseModels

/// The return leg, as a pure value.
struct ReturnHome: Equatable, Sendable {
    /// Where home is. `.theatreDepot` names a LOCATION and matches exactly;
    /// `.origin` names a bare SYSTEM and matches at system level.
    enum Destination: Equatable, Sendable {
        case theatreDepot
        case origin
        /// The theatre the resolver picks for `system` — same mesh component
        /// preferred, nearest as fallback, operational only. Names a LOCATION,
        /// so it matches exactly like `.theatreDepot`.
        case nearestTo(system: String)
    }

    /// The hulls to bring home, in the order they should be moved.
    let deviceCodes: [String]
    let destination: Destination

    init(deviceCodes: [String], destination: Destination) {
        self.deviceCodes = deviceCodes
        self.destination = destination
    }

    func next(_ ctx: StepContext) -> StepResult {
        guard let home = resolve(ctx) else {
            // Its own theatre went `.claimed` while another stands operational:
            // wait for it rather than flying the hull anywhere else.
            if destination == .theatreDepot, ctx.world.theatreWentClaimed(for: ctx.directive) {
                return .action(.wait)
            }
            return .noSubject
        }
        let arrivalTest: TravelTo.ArrivalTest = destination == .origin ? .system : .exactLocation
        var underway = false
        for code in deviceCodes {
            let leg = TravelTo(
                deviceCode: code, destination: home, arrivalTest: arrivalTest, confirmStep: nil
            )
            // A hull already crossing needs nothing ordered, and its wait is not
            // the convoy's: the hulls behind it fly alongside, not after, it.
            if leg.isUnderway(ctx) {
                underway = true
                continue
            }
            switch leg.next(ctx) {
            case .finished: continue
            // A hull the fleet read does not hold cannot be flown; the next one
            // still can, so this is not the whole leg's answer.
            case .noSubject: continue
            case let .action(action): return .action(action)
            case .more: return .more
            }
        }
        // Every hull is either home or in the air. Only the second is a wait.
        return underway ? .action(.wait) : .finished
    }

    private func resolve(_ ctx: StepContext) -> String? {
        switch destination {
        case .theatreDepot: ctx.world.theatreDepot(for: ctx.directive)
        case .origin: ctx.directive.originDesignation
        // Resolved against live readiness every evaluation, so unlike
        // `.theatreDepot` it has no claimed-theatre state to wait out.
        case let .nearestTo(system): ctx.world.theatreResolver.owningTheatre(ofSystem: system)?.depot
        }
    }
}
