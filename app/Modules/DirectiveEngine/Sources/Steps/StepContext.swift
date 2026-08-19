//
//  StepContext.swift
//  Replicould — DirectiveEngine
//
//  What a sub-machine reads: one directive, one world, one step. Every clock
//  reading comes off `world.now`, so sub-machines stay as pure as the
//  missions they serve.
//

import Foundation
import GameModels
import GameServices

/// The read-only frame a sub-machine evaluates against.
struct StepContext: Equatable, Sendable {
    let directive: Directive
    let world: WorldSnapshot
    /// The mission's own current step. A same-step dispatch names it.
    let step: String

    init(directive: Directive, world: WorldSnapshot, step: String) {
        self.directive = directive
        self.world = world
        self.step = step
    }

    /// The owner `DirectiveExecutor` stamps on this step's commands, derived
    /// from the row so the two cannot disagree.
    var owner: CommandOwner {
        CommandOwner(
            directiveID: directive.id, step: directive.step, since: directive.stepStartedAt
        )
    }

    var now: Date { world.now }
    /// How long the current step has been running.
    var elapsed: TimeInterval { world.now.timeIntervalSince(directive.stepStartedAt) }

    /// The device's live op whoever owns it — "is this device busy at all?".
    func openOperation(for code: String) -> GameModels.Operation? {
        world.openOperation(for: code)
    }

    /// The device's live op only when THIS directive owns it — "is my own
    /// command still in flight?". A co-tenant's op is invisible here.
    func ownedOperation(for code: String) -> GameModels.Operation? {
        world.openOperation(for: code, owner: directive.id)
    }

    /// `device.updatedAt >= directive.stepStartedAt`.
    func isFresh(_ device: Device) -> Bool {
        world.isFresh(device, since: directive.stepStartedAt)
    }
}
