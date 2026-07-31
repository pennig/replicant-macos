//
//  OpCompletedAuditTests.swift
//  Replicould — DirectiveEngine
//
//  The `.opCompleted` audit pass: it closes the timeline gap between "Dispatched
//  travel to X" and the next step starting. These tests pin the two properties
//  that make it safe to run on every tick — it is idempotent, and it never moves
//  the mission — alongside the terminal-status behaviour.
//

import ConcurrencyExtras
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import DirectiveEngine

/// A machine that always waits, so an evaluation exercises the audit pass and
/// nothing else.
private struct IdleMachine: MissionStepMachine {
    let kind: DirectiveKind = .surveyRun
    let firstStep = "start"
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction { .wait }
    /// Never reached: this machine only ever waits.
    func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}

private let epoch = Date(timeIntervalSince1970: 0)

private func mission(step: String = "travelling", status: DirectiveStatus = .running) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: status, deviceCode: "VES1",
        targets: ["SOL"], targetIndex: 0, step: step,
        stepStartedAt: epoch, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: epoch, updatedAt: epoch
    )
}

/// The `.commandDispatched` entry the audit pass keys off.
private func dispatchEntry(
    operationID: String,
    at occurredAt: Date = Date(timeIntervalSince1970: 100)
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "log-dispatch-\(operationID)", directiveID: "D1", deviceCode: nil,
        kind: .commandDispatched, summary: "Dispatched travel to VES1",
        step: "travelling", operationID: operationID, eventID: nil,
        occurredAt: occurredAt
    )
}

private func operation(
    id: String,
    kind: String = "travel",
    status: OperationStatus,
    lastConfirmedAt: Date = Date(timeIntervalSince1970: 500)
) -> GameModels.Operation {
    GameModels.Operation(
        id: id, entityCode: "VES1", kind: kind, status: status,
        source: .optimistic, startedAt: epoch, completesAt: nil,
        lastConfirmedAt: lastConfirmedAt, detail: .object([:])
    )
}

/// Seed a directive plus its dispatch entry and the op that entry names.
private func seed(
    _ database: any DatabaseWriter,
    operation op: GameModels.Operation,
    directive: Directive = mission()
) async throws {
    try await database.write { db in
        try Directive.insert { directive }.execute(db)
        try DirectiveLogEntry.insert { dispatchEntry(operationID: op.id) }.execute(db)
        try GameModels.Operation.insert { op }.execute(db)
    }
}

private func entries(_ database: any DatabaseReader) async throws -> [DirectiveLogEntry] {
    try await database.read { db in
        try DirectiveLogEntry.order { $0.occurredAt }.fetchAll(db)
    }
}

private func core() -> DirectiveEngineCore {
    DirectiveEngineCore(machines: [IdleMachine()], tick: .seconds(5))
}

@Suite("DirectiveExecutor .opCompleted audit")
struct OpCompletedAuditTests {

    /// The headline: a dispatched op that has since completed gets its entry, so
    /// the long quiet stretch on the timeline ends where the op actually ended.
    @Test func aClosedOpGetsItsTimelineEntry() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, operation: operation(id: "OP1", status: .completed))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core().evaluateOnce(directiveID: "D1")

            let log = try await entries(database)
            #expect(log.map(\.kind) == [.commandDispatched, .opCompleted])
            let completed = try #require(log.last)
            #expect(completed.operationID == "OP1")
            #expect(completed.summary == "travel completed")
            // Carries the step the dispatch belonged to, so the entry files under
            // the right step in the timeline.
            #expect(completed.step == "travelling")
            // Sorted where the op closed (lastConfirmedAt), not where we noticed.
            #expect(completed.occurredAt == Date(timeIntervalSince1970: 500))
        }
    }

    /// Idempotency — the pass runs every tick, so a second evaluation must not
    /// append a duplicate. This is the property that keeps a 5s loop from
    /// flooding the table.
    @Test func aSecondEvaluationDoesNotDuplicateTheEntry() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, operation: operation(id: "OP1", status: .completed))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            let engine = core()
            await engine.evaluateOnce(directiveID: "D1")
            await engine.evaluateOnce(directiveID: "D1")
            await engine.evaluateOnce(directiveID: "D1")

            let log = try await entries(database)
            #expect(log.filter { $0.kind == .opCompleted }.count == 1)
        }
    }

    /// An op still in flight is not logged — the entry means "this closed".
    @Test func anOpenOpIsNotLogged() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, operation: operation(id: "OP1", status: .active))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core().evaluateOnce(directiveID: "D1")
            let log = try await entries(database)
            #expect(log.map(\.kind) == [.commandDispatched])
        }
    }

    /// Every terminal status ends the gap, and the summary says which — a failed
    /// op left silent would be exactly the hole this pass exists to close.
    @Test(arguments: [
        (OperationStatus.failed, "travel failed"),
        (OperationStatus.rejected, "travel rejected"),
        (OperationStatus.superseded, "travel superseded"),
        (OperationStatus.unknown, "travel ended (status unknown)"),
    ])
    func anyTerminalStatusIsRecordedAndNamed(status: OperationStatus, summary: String) async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, operation: operation(id: "OP1", status: status))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core().evaluateOnce(directiveID: "D1")
            let log = try await entries(database)
            #expect(log.last?.kind == .opCompleted)
            #expect(log.last?.summary == summary)
        }
    }

    /// The safety property: the pass is audit-only. A completed op appears on the
    /// timeline without the directive's own row moving at all.
    @Test func theDirectiveRowIsUntouched() async throws {
        let database = try GameDatabase.bootstrap()
        let before = mission()
        try await seed(database, operation: operation(id: "OP1", status: .completed), directive: before)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core().evaluateOnce(directiveID: "D1")

            let after = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(after == before)
        }
    }

    /// A stamp that predates its own dispatch is clamped forward, so the pair can
    /// never render out of order in a timeline sorted by time.
    @Test func aStampEarlierThanTheDispatchIsClampedToIt() async throws {
        let database = try GameDatabase.bootstrap()
        // Dispatch is at t=100; the op claims it was confirmed at t=10.
        try await seed(database, operation: operation(
            id: "OP1", status: .completed, lastConfirmedAt: Date(timeIntervalSince1970: 10)))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core().evaluateOnce(directiveID: "D1")
            let log = try await entries(database)
            #expect(log.last?.occurredAt == Date(timeIntervalSince1970: 100))
        }
    }

    /// A future stamp is clamped back to now, so one bad clock can't park an entry
    /// at the top of a newest-first timeline forever.
    @Test func aFutureStampIsClampedToNow() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, operation: operation(
            id: "OP1", status: .completed, lastConfirmedAt: Date(timeIntervalSince1970: 9_999)))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core().evaluateOnce(directiveID: "D1")
            let log = try await entries(database)
            #expect(log.last?.occurredAt == Date(timeIntervalSince1970: 1_000))
        }
    }

    /// A non-running directive is left entirely alone — the documented gap. The
    /// entry lands once the user resumes, not behind their back.
    @Test func aStalledDirectiveLogsNothingUntilItResumes() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, operation: operation(id: "OP1", status: .completed),
                       directive: mission(status: .needsAttention))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core().evaluateOnce(directiveID: "D1")
            #expect(try await entries(database).map(\.kind) == [.commandDispatched])

            // Resumed → the entry lands on the next tick.
            try await database.write { db in
                try Directive.update { $0.status = DirectiveStatus.running }
                    .where { $0.id.eq("D1") }.execute(db)
            }
            await core().evaluateOnce(directiveID: "D1")
            #expect(try await entries(database).map(\.kind) == [.commandDispatched, .opCompleted])
        }
    }
}
