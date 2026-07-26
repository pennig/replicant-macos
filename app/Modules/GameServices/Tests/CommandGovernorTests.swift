//
//  CommandGovernorTests.swift
//  Replicould — GameServices
//
//  The governor spends the ACTIONS budget the way `PollCoordinator` spends the
//  reads budget: refuse under pressure, and never let two commands race at one
//  device. Written in the style of `PollAndDeadlineTests`' coordinator suite.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import GameSession
import Testing
@testable import GameServices

private func budgetGameClient(actionsRemaining: Int) -> GameClient {
    GameClient(
        make: { ReplicantSpace.client(apiKey: "") },
        budget: { _ in
            RateLimitGovernor.Snapshot(limit: 60, remaining: actionsRemaining, resetAt: nil)
        }
    )
}

@Suite("CommandGovernor")
struct CommandGovernorTests {
    /// With budget to spare the command goes through, and the outcome comes
    /// back untouched — the governor gates, it never reinterprets.
    @Test func dispatchesWhenBudgetAllows() async {
        let governor = CommandGovernor()
        let result = await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in .accepted(operationID: "OP1") }
        } operation: {
            await governor.dispatch(.travel, on: "VES1", params: CommandParams(destination: "SOL"))
        }
        #expect(result == .dispatched(.accepted(operationID: "OP1")))
    }

    /// At or below the floor the command is DEFERRED, not failed: the executor
    /// re-evaluates on its next tick, so the step is late rather than lost.
    @Test func defersUnderBudgetPressure() async {
        let governor = CommandGovernor(actionFloor: 6)
        let posted = LockIsolated(false)
        let result = await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 6)
            $0.commandClient.dispatch = { _, _, _ in
                posted.setValue(true)
                return .accepted(operationID: nil)
            }
        } operation: {
            await governor.dispatch(.travel, on: "VES1", params: CommandParams(destination: "SOL"))
        }
        #expect(result == .deferred(.budgetExhausted))
        #expect(posted.value == false, "a deferred command must never reach the network")
    }

    /// One token above the floor still dispatches — the boundary is `>`, so a
    /// budget exactly at the floor is the last refused value.
    @Test func dispatchesOneTokenAboveTheFloor() async {
        let governor = CommandGovernor(actionFloor: 6)
        let result = await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 7)
            $0.commandClient.dispatch = { _, _, _ in .accepted(operationID: nil) }
        } operation: {
            await governor.dispatch(.travel, on: "VES1", params: CommandParams())
        }
        #expect(result == .dispatched(.accepted(operationID: nil)))
    }

    /// One command per device: a second dispatch while the first is in flight
    /// is deferred rather than queued. Two commands racing at one device is how
    /// a mission double-issues a step after a slow POST.
    @Test func refusesASecondCommandForTheSameDevice() async {
        let governor = CommandGovernor()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let calls = LockIsolated(0)

        await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in
                calls.withValue { $0 += 1 }
                started.continuation.yield()
                for await _ in release.stream { break }
                return .accepted(operationID: nil)
            }
        } operation: {
            async let first = governor.dispatch(.travel, on: "VES1", params: CommandParams())

            // Wait until the first dispatch is genuinely inside the POST — the
            // device is claimed at that point, so the assertion below is
            // deterministic rather than a yield-timing race.
            var startedIterator = started.stream.makeAsyncIterator()
            await startedIterator.next()

            let second = await governor.dispatch(.stow, on: "VES1", params: CommandParams())
            #expect(second == .deferred(.commandInFlight))

            release.continuation.yield()
            release.continuation.finish()
            _ = await first
            #expect(calls.value == 1)
        }
    }

    /// Different devices don't block each other — the guard is per-device.
    @Test func allowsConcurrentCommandsOnDifferentDevices() async {
        let governor = CommandGovernor()
        let results = await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in .accepted(operationID: nil) }
        } operation: {
            async let a = governor.dispatch(.travel, on: "VES1", params: CommandParams())
            async let b = governor.dispatch(.travel, on: "VES2", params: CommandParams())
            return await [a, b]
        }
        #expect(results == [
            .dispatched(.accepted(operationID: nil)),
            .dispatched(.accepted(operationID: nil)),
        ])
    }

    /// The in-flight claim is released on EVERY path, including a rejection —
    /// otherwise one server 4xx would wedge that device for the session.
    @Test func releasesTheClaimAfterARejection() async {
        let governor = CommandGovernor()
        await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in .rejected("device busy") }
        } operation: {
            let first = await governor.dispatch(.travel, on: "VES1", params: CommandParams())
            #expect(first == .dispatched(.rejected("device busy")))
            let second = await governor.dispatch(.travel, on: "VES1", params: CommandParams())
            #expect(second == .dispatched(.rejected("device busy")), "the claim must not survive a rejection")
        }
    }
}
