//
//  StepResult.swift
//  Replicould — DirectiveEngine
//
//  What a sub-machine answers. It never names a mission's step: the mission
//  reads the outcome and picks what follows, which is what lets one
//  sub-machine serve sites ending in `.advanceStep`, `.done` and
//  `.advanceTarget` alike.
//

import Foundation

/// One sub-machine evaluation's outcome.
enum StepResult: Equatable, Sendable {
    /// Take this action, then ask again next tick.
    case action(MissionAction)
    /// This sub-machine's whole job is done.
    case finished
    /// One item handled and more remain — the mission returns to this
    /// sub-machine's own dispatch step.
    case more
    /// The subject does not exist: no depot to return to, no row for the
    /// device. Never a stall on its own; the mission decides.
    case noSubject
}
