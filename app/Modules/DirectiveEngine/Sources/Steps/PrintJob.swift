//
//  PrintJob.swift
//  Replicould — DirectiveEngine
//
//  Enqueuing one print at a depot: which depot anchors the decision, which
//  bench takes the job, whether the fleet evidence is good enough to order
//  against, and whether our own job is still open.
//

import Foundation
import GameModels

/// One print order at one depot, as a pure value.
struct PrintJob: Equatable, Sendable {
    /// How long a print may go unfinished before the run re-decides. Generous
    /// by a wide margin: it exists for the print that never happens, not for a
    /// slow one.
    static let deadline: TimeInterval = 30 * 60

    /// The ceiling on `deadline`'s extension while the bench is demonstrably
    /// still working. A liveness backstop for a bench that never goes idle, not
    /// an estimate of how long a queue takes.
    static let queuedCeiling: TimeInterval = 4 * 60 * 60

    /// The depot the bench must stand at. Never a device location — a hub that
    /// unfurls elsewhere must not drag the run with it.
    let depot: String

    init(depot: String) {
        self.depot = depot
    }

    /// The depot a print decision is anchored on: the run's stamped theatre,
    /// else where the pinned bench is standing. Nil is a stall at every caller.
    static func depot(for directive: Directive, in world: WorldSnapshot) -> String? {
        directive.theatreDepot ?? world.device(directive.deviceCode)?.location
    }

    /// The bench that should take `order`, or nil when every bench at this
    /// depot is occupied — a wait, never a stall, and never a dispatch onto
    /// someone else's job.
    func bench(_ ctx: StepContext, for order: PrintOrder) -> Bench? {
        PrintScheduler.choose(order, at: depot, in: ctx.world)
    }

    /// Whether this depot has any print-capable device at all.
    func hasBench(_ ctx: StepContext) -> Bool {
        !PrintScheduler.benches(at: depot, in: ctx.world).isEmpty
    }

    /// Whether this run's own print is still open, wherever substitution put it.
    /// `bench` cannot answer it: the chooser skips a bench carrying an open op,
    /// so it skips the very bench holding our job.
    func stillPrinting(_ ctx: StepContext) -> Bool {
        // `dispatchedOperations` is already scoped to this directive, legacy
        // rows with no owner column included, so kind and liveness are the filter.
        let mine = ctx.world.dispatchedOperations.values.contains {
            $0.kind == OperationKind.print.rawValue && $0.status.isOpen
        }
        return mine || ctx.ownedOperation(for: ctx.directive.deviceCode) != nil
    }

    /// Whether every row at `location` predates the step — the evidence a print
    /// decision is made against. No rows there at all is no evidence.
    static func fleetEvidenceIsStale(
        _ directive: Directive, at location: String, in world: WorldSnapshot
    ) -> Bool {
        let newest = world.devices.values
            .filter { $0.location == location }
            .map(\.updatedAt)
            .max()
        guard let newest else { return true }
        return newest < directive.stepStartedAt
    }
}
