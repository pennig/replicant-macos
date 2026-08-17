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
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "CommandGovernor")

/// Why the governor declined to POST. Both are retryable on the next tick — a
/// deferral is never a failure and never touches the directive's status.
public enum CommandDeferral: String, Sendable, Equatable {
    /// The actions bucket is at or below the reserve floor.
    case budgetExhausted
    /// Another command for this device is still in flight.
    case commandInFlight
    /// An identical command already went out in this step entry.
    case duplicate
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
    /// The floor the process-shared governor is actually built with. Named
    /// rather than left as a literal default because the brain's why-view
    /// reports it to the operator — "we stopped ourselves here" is only a
    /// legible fact if the number shown is the number enforced, and
    /// re-typing `6` in the feature is exactly how those two drift apart.
    /// Re-exported publicly as `CommandGovernorClient.actionFloor`.
    static let defaultActionFloor = 6
    /// Devices with a command in flight right now.
    private var inFlight: Set<String> = []

    init(actionFloor: Int = CommandGovernor.defaultActionFloor) {
        self.actionFloor = actionFloor
    }

    func dispatch(
        _ kind: OperationKind,
        on deviceCode: String,
        params: CommandParams,
        owner: CommandOwner?
    ) async -> CommandDispatchResult {
        guard !inFlight.contains(deviceCode) else {
            logger.debug("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (command in flight)")
            return .deferred(.commandInFlight)
        }

        if let owner {
            @Dependency(\.defaultDatabase) var database
            let digest = params.dedupKey
            let dup = (try? await database.read { db in
                try Operation
                    .where {
                        $0.directiveID.eq(owner.directiveID)
                            && $0.step.eq(owner.step)
                            && $0.entityCode.eq(deviceCode)
                            && $0.kind.eq(kind.rawValue)
                            && $0.paramsDigest.eq(digest)
                            && $0.startedAt >= owner.since
                            // A `.failed` attempt didn't land, so a repeat is
                            // a retry rather than a duplicate to refuse.
                            && $0.status.neq(OperationStatus.failed)
                    }
                    .fetchOne(db)
            }) ?? nil
            if dup != nil {
                logger.debug("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (duplicate in step \(owner.step, privacy: .public))")
                return .deferred(.duplicate)
            }
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
        let outcome = await commandClient.dispatchOwned(kind, deviceCode, params, owner)
        logger.info("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): \(String(describing: outcome), privacy: .public)")
        return .dispatched(outcome)
    }
}
