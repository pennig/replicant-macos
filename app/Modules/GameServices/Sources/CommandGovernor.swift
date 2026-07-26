//
//  CommandGovernor.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Spends the ACTIONS budget the way `PollCoordinator` spends the reads budget
//  (directives design spec §6, architecture review V3.9 blocker 3). Every
//  engine-issued command passes through here, which buys two things a single
//  directive executor could not give itself:
//
//    • Budget-aware deferral: under actions-bucket pressure the command is
//      DEFERRED, not failed — the executor re-evaluates on its next tick, so a
//      busy minute makes a step late rather than stalling the mission.
//    • Per-device in-flight guard: one command per device at a time. Two
//      executors (or an executor and a future UI adopter) cannot race a second
//      POST at a device whose first is still open — the shape that
//      double-issues a step after a slow response.
//
//  An actor so the claim set stays consistent under concurrent dispatches.
//  Deliberately does NOT reinterpret outcomes: gating is the whole job, and the
//  `CommandOutcome` comes back verbatim.
//
//  Built as shared infrastructure rather than inside `DirectiveEngine` so the
//  manual UI command paths can adopt it later without moving it.
//

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "CommandGovernor")

/// Why the governor declined to POST. Both are retryable on the next tick — a
/// deferral is never a failure and never touches the directive's status.
public enum CommandDeferral: String, Sendable, Equatable {
    /// The actions bucket is at or below the reserve floor.
    case budgetExhausted
    /// Another command for this device is still in flight.
    case commandInFlight
}

/// The result of asking the governor to dispatch.
public enum CommandDispatchResult: Sendable, Equatable {
    /// The command reached `CommandClient`; the outcome is its verdict verbatim.
    case dispatched(CommandOutcome)
    /// The command never left — retry on a later evaluation.
    case deferred(CommandDeferral)
}

actor CommandGovernor {
    /// Defer once the actions bucket drops to this many tokens. Proportional to
    /// `PollCoordinator`'s reads floor (12 of 120/min) against the 60/min
    /// actions limit, leaving headroom for manual UI commands and the CLI.
    private let actionFloor: Int
    /// Devices with a command in flight right now.
    private var inFlight: Set<String> = []

    init(actionFloor: Int = 6) {
        self.actionFloor = actionFloor
    }

    func dispatch(
        _ kind: OperationKind,
        on deviceCode: String,
        params: CommandParams
    ) async -> CommandDispatchResult {
        guard !inFlight.contains(deviceCode) else {
            logger.debug("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (command in flight)")
            return .deferred(.commandInFlight)
        }

        @Dependency(\.gameClient) var gameClient
        let budget = await gameClient.budget(.actions)
        // Re-check after the suspension above: an interleaved dispatch may have
        // claimed the device while this one awaited the budget snapshot.
        guard !inFlight.contains(deviceCode) else {
            logger.debug("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (claimed during budget read)")
            return .deferred(.commandInFlight)
        }
        guard budget.remaining > actionFloor else {
            logger.notice("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (actions budget \(budget.remaining) ≤ floor \(self.actionFloor))")
            return .deferred(.budgetExhausted)
        }

        inFlight.insert(deviceCode)
        // Released on EVERY path — a rejection that kept the claim would wedge
        // that device for the rest of the session.
        defer { inFlight.remove(deviceCode) }

        @Dependency(\.commandClient) var commandClient
        let outcome = await commandClient.dispatch(kind, deviceCode, params)
        logger.info("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): \(String(describing: outcome), privacy: .public)")
        return .dispatched(outcome)
    }
}
