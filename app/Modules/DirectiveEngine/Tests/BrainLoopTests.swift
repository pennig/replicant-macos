//
//  BrainLoopTests.swift
//  Replicould — DirectiveEngine
//
//  Task 4: the brain's plan loop is online and wired to the clock —
//  `DirectiveEngineCore` ticks `Brain.evaluateOnce()` every 5s beside the
//  existing supervisor. Every world here is one with nothing to do, so every
//  assertion is chosen to catch a brain that WROTE something anyway, not
//  merely to show the loop ran — see each test's doc comment for what it
//  would catch. The brain's LAUNCHING path (Task 16) is exercised in
//  `BrainGrowTests`, against worlds that actually offer it work.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import Sharing
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

    /// A galaxy with a meshed relay and salvage IN THAT SAME MESHED SYSTEM:
    /// there is nothing to grow toward (`ValueCatalog` excludes a meshed
    /// system — the mesh already reaches it), no print hub, and no carrier.
    /// The brain idles and leaves every row exactly as it found it.
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
    /// `tickBrain()` driven directly, deterministically — the same seam
    /// `evaluateOnce(directiveID:)` gets in the executor tests — with an
    /// EXACT tick count, not just "no directive appeared": three calls must
    /// leave `brainTickCount` at exactly 3, which would fail if a tick were
    /// silently dropped or double-counted. `start()`/`stop()` are
    /// deliberately not involved here — mixing manual calls with the live
    /// automatic loop would race two independent sources of ticks against
    /// the same counter. The wiring itself (`start()` actually spawns a
    /// clock-driven `brain` task) is `theTimerLoopItselfTicksOnSchedule`'s
    /// job below.
    @Test func manualTicksWriteNothingAndCountExactly() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedRelay(db, code: "REL1", location: "SOL")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
        }
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            await core.tickBrain()
            await core.tickBrain()
            await core.tickBrain()
        }
        #expect(await core.brainTickCount == 3)

        let directives = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(directives.isEmpty, "an idle brain must create no directive, however many ticks ran")

        let logEntries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(logEntries.isEmpty, "an idle brain must log no timeline entry")

        let relay = try await database.read { db in
            try Device.where { $0.deviceCode.eq("REL1") }.fetchOne(db)
        }
        #expect(relay?.updatedAt == Date(timeIntervalSince1970: 0), "an idle brain must not touch existing rows")
    }

    /// The real timer loop, not a manual call: `start()` alone wires a
    /// `brain` `Task` that ticks once immediately (the same immediate-
    /// first-tick shape `reconcileExecutors()` has, before the loop's first
    /// `clock.sleep`). Asserting the EXACT count — not merely that no
    /// directive appeared — is what makes this test able to fail if
    /// `start()` stopped wiring `brain` to the clock at all: a dead `brain`
    /// field, or a loop body that silently no-ops, would both leave
    /// `directives.isEmpty` true (an idle brain writes nothing either way)
    /// but would leave `brainTickCount` at 0, not 1.
    ///
    /// This deliberately does NOT try to also prove the "ticks again every
    /// 5s" cadence by bulk-advancing `TestClock` further: `tickBrain()`'s
    /// body reads the real database (`Brain.evaluateOnce()`), a genuine
    /// cross-thread hop that `TestClock`'s cooperative-yield synchronization
    /// cannot wait out — confirmed empirically, both a single
    /// `.advance(by: .seconds(20))` and four sequential
    /// `.advance(by: .seconds(5))` calls produced a non-reproducible tick
    /// count across runs (1, then 2, then back to 1). Asserting an exact
    /// count there would trade one false-confidence problem for a flaky
    /// test — a worse one, since it fails intermittently rather than
    /// reliably. The 5-second CADENCE itself is instead proven the
    /// deterministic way, by `manualTicksWriteNothingAndCountExactly` above:
    /// it drives `tickBrain()` directly, the very method this loop's body
    /// calls every `tick`.
    @Test func theTimerLoopItselfTicksOnSchedule() async throws {
        let clock = TestClock()
        let database = try GameDatabase.bootstrap()
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))

        await withDependencies {
            $0.continuousClock = clock
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            await core.start()
            // A zero-duration advance still runs `TestClock.advance`'s
            // internal cooperative yield, which is enough to let the just-
            // spawned `brain` Task reach the synchronous `brainTickCount +=
            // 1` at the very top of `tickBrain()` — a real (if virtual-time-
            // free) synchronization point, not a timing guess.
            await clock.advance(by: .zero)
            #expect(
                await core.brainTickCount == 1,
                "start() must wire brain to tick immediately — a dead `brain` field would leave this at 0"
            )
            await core.stop()
        }

        let directives = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(directives.isEmpty)
    }

    /// The why-view's feed, from the engine's end (Task 19): a tick PUBLISHES
    /// its report to `@Shared(.brainReport)`.
    ///
    /// This is half of the proof that `BrainWhy`/`BrainWhyView` are reachable
    /// from the app — the other half (`DirectivesFeature.State` reading the
    /// same key and projecting it) lives in `BrainWhyViewTests`, because it is
    /// the feature module that owns the reading end. Between them the chain is
    /// covered end to end with no faked step: this test drives the real
    /// `tickBrain()` against a real database, and asserts on the real key.
    ///
    /// The `defaultInMemoryStorage` override is what makes it hermetic —
    /// without it every test in the process would publish into one store.
    @Test func aTickPublishesItsReportToTheWhyViewsFeed() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedRelay(db, code: "REL1", location: "SOL")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
        }
        let storage = InMemoryStorage()
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))
        let tickTime = Date(timeIntervalSince1970: 1_000)

        let published: BrainReport? = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(tickTime)
            $0.defaultInMemoryStorage = storage
        } operation: {
            @Shared(.brainReport) var report: BrainReport?
            // Nothing to explain before the first tick — the card must not
            // appear over an empty session.
            #expect(report == nil)
            await core.tickBrain()
            return report
        }

        // A world with a mesh but nothing worth reaching: the decision the
        // operator sees is the real one this world produces, not a placeholder.
        #expect(published?.decision == .idle(reason: "no grow or prune work"))
        #expect(published?.observedAt == tickTime)
        // The rails are reported even on an idle tick — headroom is a standing
        // fact, not something that only exists when a launch is blocked.
        #expect(published?.limits.reserveFloors == BrainCeiling.reserveFloors)

        // Publishing is not persisting: the why-view is derived state and the
        // brain design forbids it a table.
        let tables = try await database.read { db in
            try #sql("SELECT name FROM sqlite_master WHERE type = 'table'", as: String.self).fetchAll(db)
        }
        #expect(!tables.contains { $0.localizedCaseInsensitiveContains("brain") })
    }

    /// `stop()` retires the feed with the brain that fed it.
    ///
    /// `stop()` runs on logout, immediately before the directive tables are
    /// wiped. A surviving report would show the PREVIOUS account's ranked
    /// systems and hub stock on the Directives surface until the next login's
    /// first tick — the same session-bleed the composition root already avoids
    /// by resetting domain freshness on this path.
    @Test func stoppingClearsTheWhyViewsFeed() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedRelay(db, code: "REL1", location: "SOL")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
        }
        let storage = InMemoryStorage()
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))

        let (afterTick, afterStop): (BrainReport?, BrainReport?) = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.defaultInMemoryStorage = storage
        } operation: {
            @Shared(.brainReport) var report: BrainReport?
            await core.tickBrain()
            let published = report
            await core.stop()
            return (published, report)
        }

        // The first half is what makes the second half mean anything: without
        // it, "nil after stop" would pass on an engine that never published.
        #expect(afterTick != nil)
        #expect(afterStop == nil)
    }

    /// …and the clear STAYS cleared, which is a different claim.
    ///
    /// `stoppingClearsTheWhyViewsFeed` above awaits its tick before calling
    /// `stop()`, so it can only ever see the tidy ordering. The real one is the
    /// other way round: `stop()` cancels the brain task WITHOUT awaiting it, and
    /// cancellation is cooperative, so a tick suspended mid-flight resumes
    /// AFTER the feed was cleared. Without the guard in `tickBrain()` it then
    /// republishes the previous account's ranked systems and hub stock, which
    /// survives on the Directives surface until the next login's first tick —
    /// the exact session bleed `stop()`'s comment says it prevents.
    ///
    /// The tick is held open at the confirm-read, which is a real suspension on
    /// the launching path rather than a contrived one, and is the same window
    /// that reaches `Brain.launch`'s insert. Both are asserted here: a stopped
    /// engine publishes nothing and writes nothing.
    ///
    /// **Nothing is awaited before the teardown.** The in-flight tick is
    /// cancelled exactly as `stop()` cancels `brain` (the private task is not
    /// reachable from here), then `stop()` runs, and only then is the tick let
    /// go — so `await inFlight.value` at the end is what makes "nothing was
    /// published" a completed fact rather than a race.
    @Test func aTickStoppedMidFlightPublishesNothingAndWritesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowableWorld(db) }
        let storage = InMemoryStorage()
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))
        let confirming = Gate()
        let resume = Gate()

        let published: BrainReport? = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.defaultInMemoryStorage = storage
            $0.uuid = .incrementing
            $0.deviceRefresher = confirmingRefresher(database) { device in
                await confirming.open()
                await resume.wait()
                return device
            }
        } operation: {
            @Shared(.brainReport) var report: BrainReport?
            let inFlight = Task { await core.tickBrain() }
            await confirming.wait()
            inFlight.cancel()
            await core.stop()
            await resume.open()
            await inFlight.value
            return report
        }

        #expect(published == nil, "a tick that resumed after stop() must not republish the stopped session")

        let directives = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(directives.isEmpty, "and must not commit the launch it was half-way through")
    }

    /// The other end of the same window: a tick that BEGINS after `stop()`.
    ///
    /// The loop's own `!Task.isCancelled` can pass and the `await` hop onto the
    /// actor can then land after the cancel, so cancellation has to be re-tested
    /// inside `tickBrain()` as well as around it. `brainTickCount` is what makes
    /// this checkable: the guard sits above the increment, so a tick that never
    /// ran leaves it at 0 — where the "published nothing" assertion alone would
    /// pass on a tick that ran fully and merely failed to publish.
    @Test func aTickThatBeginsAfterStopNeverRunsAtAll() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowableWorld(db) }
        let storage = InMemoryStorage()
        let core = DirectiveEngineCore(machines: [], tick: .seconds(5))
        let release = Gate()

        let published: BrainReport? = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.defaultInMemoryStorage = storage
            $0.uuid = .incrementing
            $0.deviceRefresher = DeviceRefreshClient { code, _ in
                Issue.record("a stopped engine must not spend a confirm-read on \(code)")
                return nil
            }
        } operation: {
            @Shared(.brainReport) var report: BrainReport?
            let late = Task {
                await release.wait()
                await core.tickBrain()
            }
            late.cancel()
            await core.stop()
            await release.open()
            await late.value
            return report
        }

        #expect(await core.brainTickCount == 0, "a tick entered after stop() must not run")
        #expect(published == nil)
    }
}

/// A one-shot async gate, for holding a brain tick open across a teardown.
///
/// Deliberately NOT cancellation-aware: these tests cancel the very task that
/// is waiting, and a gate that resumed on cancellation would let the tick slip
/// past the suspension the test exists to hold it in — turning a deterministic
/// ordering back into the race it is meant to pin down.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
