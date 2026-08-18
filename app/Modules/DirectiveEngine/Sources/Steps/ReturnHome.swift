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
        for code in deviceCodes {
            let leg = TravelTo(
                deviceCode: code, destination: home, arrivalTest: arrivalTest, confirmStep: nil
            )
            switch leg.next(ctx) {
            case .finished: continue
            // A hull the fleet read does not hold cannot be flown; the next one
            // still can, so this is not the whole leg's answer.
            case .noSubject: continue
            case let .action(action): return .action(action)
            case .more: return .more
            }
        }
        return .finished
    }

    private func resolve(_ ctx: StepContext) -> String? {
        switch destination {
        case .theatreDepot: ctx.world.theatreDepot(for: ctx.directive)
        case .origin: ctx.directive.originDesignation
        }
    }
}
