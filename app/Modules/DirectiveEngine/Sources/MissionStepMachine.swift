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
    /// Move to `nextStep` with no command at all. The machine's way of saying
    /// "this step's work was already done" — a target already reached, a
    /// directive already configured — without a pointless POST.
    case advanceStep(nextStep: String)
    /// Record the AMI controller this run is driving, then move on. The
    /// ownership handshake `Directive.controllerCode` exists for: it is what
    /// badges and locks the controller's built-in row while the mission runs.
    case assignController(deviceCode: String, nextStep: String)
    /// Re-read `locations/{star}`, persist it, then move to `nextStep`. The
    /// engine owns the I/O; the machine sees the fresh counts on its next
    /// evaluation. Presence-gated (403 away from the system), so only ever
    /// asked for after arrival.
    case refreshSystem(designation: String, nextStep: String)
    /// "Before I believe this, read it." The engine re-reads each named device
    /// authoritatively — plus whatever those devices report stowed aboard them,
    /// because containment is a two-ended fact and one end alone can't settle it
    /// — then asks the machine again against the fresh snapshot. If the machine
    /// still wants a refresh, the engine stalls with `thenStall` instead.
    ///
    /// This exists because a `WorldSnapshot` is a read of local SQLite, and those
    /// rows are kept current by `.low` confirm-reads that the read-budget floor
    /// may defer indefinitely. Without this, a mission could not tell "the vessel
    /// is genuinely unstaged" from "we have not been allowed to look recently",
    /// and it stalled on the second as if it were the first — the run that
    /// prompted this went `noSurveyControllerAboard` on a controller the server
    /// had already re-stowed, and no amount of Retry could clear it, because
    /// Retry re-runs a pure function over the identical stale snapshot.
    ///
    /// The reads are `.high`, so they bypass the TTL and the budget floor: this
    /// is issued only where the alternative is a dead stop that needs a human.
    /// Exactly ONE refresh-and-re-ask per evaluation — never a loop.
    ///
    /// **Name every device the answer depends on.** The engine expands each
    /// named device into whatever that CARRIER reports stowed aboard it, but a
    /// carrier's `stowed_devices` blob is not a reliable inverse of the
    /// children's own `stowedInDeviceCode` columns — a real vessel's blob listed
    /// one unrelated device while six drones claimed to be aboard it. Relying on
    /// the expansion to reach a row you are judging is how a check ends up
    /// permanently unsatisfiable.
    ///
    /// `thenStall: nil` means "if the re-ask still wants a refresh, just wait".
    /// That is the right fallback whenever the unresolved state is *expected*
    /// rather than wrong — a recall genuinely still in flight is not a fault,
    /// and stalling on it would demand a human for something that fixes itself.
    case refreshDevices(deviceCodes: [String], thenStall: DirectiveAttentionReason?)
    /// The same demand, scoped to a whole system instead of a device list:
    /// `GET devices?location=<designation>` in ONE request, reconciled, then the
    /// machine is asked again exactly as `.refreshDevices` does.
    ///
    /// Prefer this whenever the answer depends on several devices in one place.
    /// A recall probe needs the vessel, the controller and every drone still
    /// out — eight per-device reads, where this is one, and one that does not
    /// grow with the fleet. It also sidesteps the carrier-expansion trap
    /// entirely: nothing has to be named, so nothing can be missed.
    ///
    /// In-transit devices ARE included. A travelling device reports
    /// `location: null` yet the server still matches it to the system (probed
    /// live 2026-07-27), which is exactly the case that matters here — the
    /// drones worth waiting for are the ones in flight.
    case refreshDevicesInSystem(designation: String, thenStall: DirectiveAttentionReason?)
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
