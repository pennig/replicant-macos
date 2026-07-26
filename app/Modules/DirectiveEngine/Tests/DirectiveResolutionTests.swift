//
//  DirectiveResolutionTests.swift
//  Replicould — DirectiveEngine
//
//  The five stall-resolution transitions. Each is a row change plus its
//  timeline entry in one transaction, and each refuses to run from a status it
//  doesn't apply to — the UI shouldn't offer it, but a stale click must not
//  corrupt the row.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import DirectiveEngine

private func stalled(
    _ reason: DirectiveAttentionReason = .commandRejected,
    step: String = "configuring",
    targets: [String] = ["TAU", "SOL"],
    targetIndex: Int = 0,
    status: DirectiveStatus = .needsAttention
) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: status, deviceCode: "VES1",
        controllerCode: "AMI1", targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: Date(timeIntervalSince1970: 100),
        returnToOrigin: false, originDesignation: "SOL",
        attentionReason: status == .needsAttention ? reason : nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func seed(_ directive: Directive) async throws -> any DatabaseWriter {
    let database = try GameDatabase.bootstrap()
    try await database.write { db in try Directive.insert { directive }.execute(db) }
    return database
}

private func load(_ database: any DatabaseWriter) async throws -> Directive? {
    try await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
}

private func entries(_ database: any DatabaseWriter) async throws -> [DirectiveLogEntry] {
    try await database.read { db in try DirectiveLogEntry.order { $0.occurredAt }.fetchAll(db) }
}

@Suite("Directive resolution")
struct DirectiveResolutionTests {
    /// Retry hands the run back to the engine on the SAME step, with
    /// `stepStartedAt` re-stamped — which is what lets a surveyIncomplete stall
    /// recover instead of instantly re-stalling on the same stale completion.
    @Test func retryClearsTheStallAndRestampsTheStep() async throws {
        let database = try await seed(stalled(.surveyIncomplete, step: "confirming"))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.retry("D1")
        }
        let directive = try await load(database)
        #expect(directive?.status == .running)
        #expect(directive?.attentionReason == nil)
        #expect(directive?.step == "confirming")
        #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 5_000))
        let log = try await entries(database)
        #expect(log.map(\.kind) == [.resolved])
        #expect(log.first?.directiveID == "D1")
    }

    /// Skip advances the queue and restarts at the machine's first step, so the
    /// next target begins with a fresh preflight rather than mid-procedure.
    @Test func skipTargetAdvancesAndRestartsTheMachine() async throws {
        let database = try await seed(stalled(step: "configuring", targetIndex: 0))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.skipTarget("D1")
        }
        let directive = try await load(database)
        #expect(directive?.targetIndex == 1)
        #expect(directive?.step == SurveyRun().firstStep)
        #expect(directive?.status == .running)
        #expect(directive?.attentionReason == nil)
        #expect(directive?.currentTarget == "SOL")
    }

    /// Skipping the LAST target leaves an exhausted queue, which the machine
    /// resolves to `.done` on its next evaluation — not an error state.
    @Test func skippingTheLastTargetExhaustsTheQueue() async throws {
        let database = try await seed(stalled(targets: ["TAU"], targetIndex: 0))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.skipTarget("D1")
        }
        let directive = try await load(database)
        #expect(directive?.targetIndex == 1)
        #expect(directive?.currentTarget == nil)
        #expect(directive?.status == .running)
    }

    /// Cancel ends the run. It deliberately does NOT clear the controller's AMI
    /// directive — that's a server command with its own failure modes, and
    /// cancelling releases ownership so the user can Clear it deliberately.
    @Test func cancelEndsTheRunAndReleasesTheController() async throws {
        let database = try await seed(stalled())
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.cancel("D1")
        }
        let directive = try await load(database)
        #expect(directive?.status == .cancelled)
        #expect(directive?.attentionReason == nil)
        #expect(directive?.controllerCode == "AMI1", "the record of what it drove survives")
    }

    /// Pause takes a running directive out of the engine's reach.
    @Test func pauseStopsARunningDirective() async throws {
        let database = try await seed(stalled(step: "awaiting", status: .running))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.pause("D1")
        }
        #expect(try await load(database)?.status == .paused)
    }

    /// Resume re-stamps the step for the same reason retry does.
    @Test func resumeRestartsAPausedDirective() async throws {
        let database = try await seed(stalled(step: "awaiting", status: .paused))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.resume("D1")
        }
        let directive = try await load(database)
        #expect(directive?.status == .running)
        #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 5_000))
    }

    /// A verb applied from a status it doesn't apply to is a no-op. The UI
    /// shouldn't offer it, but a stale click must not corrupt the row.
    @Test func verbsRefuseInapplicableStatuses() async throws {
        let database = try await seed(stalled(step: "awaiting", status: .running))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.retry("D1")     // only from needsAttention
            await resolution.resume("D1")    // only from paused
        }
        let directive = try await load(database)
        #expect(directive?.step == "awaiting")
        #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 100), "untouched")
        #expect(try await entries(database).isEmpty)
    }

    /// Cancelling an already-finished run writes nothing.
    @Test func cancelIsANoOpOnAFinishedRun() async throws {
        let database = try await seed(stalled(status: .completed))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.cancel("D1")
        }
        #expect(try await load(database)?.status == .completed)
        #expect(try await entries(database).isEmpty)
    }

    /// A missing directive id is a no-op, not a crash.
    @Test func unknownDirectiveIsANoOp() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
            // The client is loud by default (`unimplemented`); these tests
            // exercise the real transitions against an in-memory database.
            $0.directiveResolution = .liveValue
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.retry("NOPE")
        }
        #expect(try await entries(database).isEmpty)
    }

    /// The registry is the single source of mission registration — the engine
    /// and resolution must agree on which machines exist.
    @Test func registryKnowsSurveyRunAndNotRelayRun() {
        #expect(MissionRegistry.firstStep(for: .surveyRun) == SurveyRun().firstStep)
        #expect(MissionRegistry.firstStep(for: .relayRun) == nil)
    }
}
