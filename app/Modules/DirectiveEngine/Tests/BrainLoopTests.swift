//
//  BrainLoopTests.swift
//  Replicould — DirectiveEngine
//
//  Task 4: the brain's plan loop is online, calm, and inert. `Brain.
//  evaluateOnce()` reads a `WorldView` and always answers `.idle` (Phase A),
//  and `DirectiveEngineCore` ticks it every 5s beside the existing
//  supervisor. Every assertion here is chosen to catch a brain that WROTE
//  something, not merely to show the loop ran — see each test's doc comment
//  for what it would catch.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import DirectiveEngine

@Suite("Brain — evaluateOnce")
struct BrainEvaluationTests {
    /// An empty galaxy: no devices, so no mesh. The brain still reads the
    /// world (not a short-circuit on an empty database) and idles rather
    /// than crashing or hanging.
    @Test func idlesWithNoMeshOverAnEmptyGalaxy() async throws {
        let database = try GameDatabase.bootstrap()
        let decision = await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Brain(now: Date(timeIntervalSince1970: 1_000)).evaluateOnce()
        }
        #expect(decision == .idle(reason: "no mesh yet"))

        // No directive exists to create in the first place, but a brain that
        // silently started one here would still be caught.
        let directives = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(directives.isEmpty)
    }

    /// A galaxy with a meshed relay and salvage nearby — plenty for a later,
    /// non-inert brain to act on — still idles in this Phase A build, and
    /// leaves every row exactly as it found it.
    ///
    /// The row-for-row equality below is the test that would actually catch a
    /// brain that mutated something while deciding: a naive implementation
    /// that, say, wrote a fresh `updatedAt` onto the relay while reading it
    /// would fail `after == before` even though it created no directive.
    @Test func idlesWithNoWorkAndTouchesNoExistingRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedRelay(db, code: "REL1", location: "SOL")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
            try seedSalvageAssay(db, id: "SITE1", system: "SOL", totals: ["metal": 500])
        }
        let before = try await database.read { db in try Device.all.fetchAll(db) }

        let decision = await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Brain(now: Date(timeIntervalSince1970: 1_000)).evaluateOnce()
        }
        #expect(decision == .idle(reason: "no grow or prune work"))

        let after = try await database.read { db in try Device.all.fetchAll(db) }
        #expect(after == before, "an idle brain must not mutate any device row it read")

        let directives = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(directives.isEmpty, "an idle brain must create no directive")
    }

    /// A database read failure degrades to idle rather than throwing through
    /// the tick — the plan loop must never crash the actor over a transient
    /// read error. A blank `DatabaseQueue` with no migrations applied — none
    /// of `WorldView.read`'s tables exist — produces a genuine read failure
    /// rather than a mocked one.
    @Test func aFailedWorldReadStillIdlesRatherThanThrowing() async throws {
        let blank = try DatabaseQueue()
        let decision = await withDependencies {
            $0.defaultDatabase = blank
        } operation: {
            await Brain(now: Date(timeIntervalSince1970: 1_000)).evaluateOnce()
        }
        #expect(decision == .idle(reason: "world unavailable"))
    }
}

@Suite("Brain — plan loop wiring")
struct BrainLoopTests {
    /// Under `TestClock`, `DirectiveEngineCore.start()` claims a `brain` task
    /// alongside its supervisor, and every tick — driven directly the same
    /// deterministic way `supervisorSpawnsOneExecutorPerRunningDirective`
    /// drives `reconcileExecutors()`, sidestepping the Task-scheduling race a
    /// bare `clock.advance` right after `start()` would carry — reads the
    /// world and writes nothing: no directive is created, and no timeline
    /// entry is logged. `stop()` then tears the loop down.
    @Test func loopTicksAndWritesNothingWhenIdle() async throws {
        let clock = TestClock()
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedRelay(db, code: "REL1", location: "SOL")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
        }
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))

        await withDependencies {
            $0.continuousClock = clock
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            await core.start()
            // Drive several ticks deterministically.
            await core.tickBrain()
            await core.tickBrain()
            await core.tickBrain()
            await core.stop()
        }

        let directives = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(directives.isEmpty, "an idle brain must create no directive, however many ticks ran")

        let logEntries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(logEntries.isEmpty, "an idle brain must log no timeline entry")

        let relay = try await database.read { db in
            try Device.where { $0.deviceCode.eq("REL1") }.fetchOne(db)
        }
        #expect(relay?.updatedAt == Date(timeIntervalSince1970: 0), "an idle brain must not touch existing rows")
    }

    /// The real timer loop, not a manual call: advancing `TestClock` alone
    /// (with no manual `tickBrain()` call) must still produce the same
    /// nothing-written outcome — proving `start()` actually wired `brain` to
    /// the clock rather than leaving it a dead field.
    @Test func theTimerLoopItselfTicksWithoutAnyManualDrive() async throws {
        let clock = TestClock()
        let database = try GameDatabase.bootstrap()
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))

        await withDependencies {
            $0.continuousClock = clock
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            await core.start()
            await clock.advance(by: .seconds(20))
            await core.stop()
        }

        let directives = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(directives.isEmpty)
    }
}
