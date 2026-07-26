//
//  MissionStepMachine.swift
//  Replicould — DirectiveEngine
//
//  A mission is a pure step machine: (directive state, world snapshot) → ONE
//  action. The engine owns every side effect — dispatching, writing rows,
//  waiting — and mission logic owns none, so the stall matrix (directives
//  design spec §8) is a table of plain function calls over fixtures.
//
//  No machines ship in this stage: Survey Run is Stage 4, Relay Run is Stage 5.
//  The engine's registry is empty in production and populated by fakes in tests.
//

import Foundation
import GameModels
import GameServices

/// What a mission wants to happen next. Exactly one per evaluation — a machine
/// that needs two things in a row expresses the second on the next tick, which
/// is what keeps every step recoverable after a relaunch (spec §11).
public enum MissionAction: Equatable, Sendable {
    /// POST a command, then move to `nextStep`. The engine routes it through
    /// `CommandGovernor`, so a deferral is invisible to the machine — it is
    /// simply asked again.
    case dispatch(kind: OperationKind, deviceCode: String, params: CommandParams, nextStep: String)
    /// Nothing to do yet — something server-side is still in progress. Expected
    /// and cheap; the engine takes no action at all.
    case wait
    /// Pause and surface. The engine sets `needsAttention` plus the typed reason
    /// and stops evaluating until the user resolves it. Never auto-retried at
    /// the mission layer (spec §8).
    case stall(DirectiveAttentionReason)
    /// This target is finished; move to the next one.
    case advanceTarget
    /// The whole run is finished.
    case done
}

/// One mission kind's procedure.
public protocol MissionStepMachine: Sendable {
    /// The directive kind this machine runs.
    var kind: DirectiveKind { get }
    /// The step a freshly-started target begins on. The engine writes it when
    /// advancing the queue, so the machine owns its own step vocabulary —
    /// which is why `Directive.step` is a bare `String` and not an enum.
    var firstStep: String { get }
    /// The single next action. MUST be pure: no I/O, no clock reads (use
    /// `world.now`), no randomness.
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction
}
