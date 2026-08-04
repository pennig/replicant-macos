//
//  BrainDegradationTests.swift
//  Replicould — DirectiveEngine
//
//  Task 26: the evidence for the last two robustness clauses.
//
//    • **Clause 6 — safe degradation.** A transient failure DEFERS (and a
//      deferred tick writes nothing and spends nothing); an UNKNOWN world is
//      left alone (no value data ⇒ no target); a PERSISTENT failure retries on
//      a real backoff and then ESCALATES. And the pair that must never look
//      alike: a brain with nothing to do reports `.idle` and surfaces nothing,
//      while a brain that is stuck reports `.stall` and leaves a
//      `.needsAttention` row for a human.
//    • **Clause 7 — bounded blast radius.** The worst case of any single
//      decision is a wasted trip or an operator-resolvable stall. Grow spend is
//      bounded by the `R` reserve rail; a reclaim never strands live value; and
//      every write the brain makes is additive.
//
//  **The two rails Task 25's lifecycle gate traverses but never LOADS, loaded
//  here.** That gate seeds its world with 999,999 units, so
//  `RelayRun.printStockIsShort` permits every print; and nothing in it races,
//  so `Brain.commitBlocker` never refuses anything. Both could be deleted and
//  that suite would stay green. This file is where they are made to fire:
//
//    1. `theReserveRailVetoesThePrintAndTheBrainIdlesInsteadOfThrashing` drives
//       a genuinely below-floor world through the real `RelayRun` and proves the
//       print is never dispatched — then keeps driving for fifty virtual
//       minutes to prove the refusal costs a bounded, countable number of API
//       reads rather than one per tick.
//    2. `aRacingClaimOnTheSameSpareRelayIsRefusedAtCommitTime` loads
//       `commitBlocker`'s THIRD guard — `inFlightSources` — which had no test
//       anywhere in the package before this file: the two operator-race tests
//       in `BrainConfirmFreshTests` cover the carrier and the target arms only.
//
//  **Fake seam placement matches Task 25's**: `commandClient` (the wire),
//  `locationsClient.footprint` (the `GET /v1/locations` read the rail consults)
//  and `deviceRefresher` (the authoritative device read) are scripted; the real
//  `Brain`, the real `DirectiveEngineCore` loop bodies, the REGISTERED
//  `RelayRun` from `MissionRegistry.machines`, the real `DirectiveExecutor`,
//  the real `CommandGovernor.liveValue` and the real
//  `DirectiveResolutionClient.liveValue.retry` all run.
//
//  **On `uuid`**: bound ONCE per test and threaded into every tick.
//  `UUIDGenerator.incrementing` is a computed property, so re-entering
//  `withDependencies` per tick would mint the same id every time and make every
//  row-count assertion here incapable of failing (the second insert would
//  collide on the primary key and degrade to `.idle` whatever the gate did).
//
//  **On driving ticks**: directly, one virtual step per iteration, exactly as
//  `BrainGrowLifecycleE2ETests` does and for the reason `BrainLoopTests`
//  records empirically — advancing a `TestClock` past the loop's real database
//  read is not reproducible. A `TestClock` is installed regardless so nothing
//  can sleep for real.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import GameSession
import Sharing
import SQLiteData
import Testing
import UniverseModels
import Utils

@testable import DirectiveEngine

// MARK: - The world

/// The instant every world here is seeded AT. Device rows are stamped with it
/// rather than the epoch: `RelayRun.acquire` refuses to trust a hub row older
/// than `hubFreshness` (5 min), so an epoch-stamped fleet would spend every
/// test in a refresh-then-stall loop instead of reaching the rail under test.
private let liftoff = Date(timeIntervalSince1970: 2_000_000)

/// Where the autofactory and the carrier stand — inside the meshed `SOL`
/// system, which is what makes `WorldView.hubLocation` non-nil.
private let hubLocation = "SOL-3"

/// The grow target these worlds rank first.
private let target = "VEGA"

/// A stock reading comfortably BELOW `BrainCeiling.aggregateSpendFloor`
/// (35,078). Not zero, and that is the point: the rail must veto on a world
/// that plainly holds resources — enough for ninety-odd relays at the 370-unit
/// bill — because what it protects is the RESERVE, not the last unit. A
/// zero-stock fixture would pass against a rail that only refused to spend
/// money it did not have.
private let belowFloorStock = 34_000

/// A stock reading above the floor, for the positive control.
private let aboveFloorStock = 200_000

/// The smallest world that ranks one grow candidate: `SOL` meshed by one live
/// relay, an autofactory and a HEAVEN vessel standing together at `SOL-3`, a
/// census row carrying `hubStock`, and one salvage system 5 ly out.
///
/// `salvage` is a parameter because the UNKNOWN-value clause needs the same
/// world with the value data removed and nothing else changed — two worlds that
/// differ in one fact are what makes "no value data yields no target" a
/// statement about the value data.
private func seedDegradationWorld(
    _ db: Database,
    hubStock: Int = belowFloorStock,
    salvage: Double? = 3_200,
    carriers: [String] = ["VDEG1"]
) throws {
    try seedRelay(db, code: "RELDEG_1", location: "SOL", updatedAt: liftoff)
    try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
    try seedSystemDetail(db, system: "SOL", scanned: true)
    try seedPrintHub(db, code: "HUBDEG", location: hubLocation, updatedAt: liftoff)
    for code in carriers {
        try seedDevice(db, code: code, type: "heaven_vessel", location: hubLocation, updatedAt: liftoff)
    }

    try seedStar(db, designation: target, x: 5, y: 0, z: 0)
    if let salvage {
        try seedSalvageAssay(db, id: "SITE-\(target)", system: target, totals: ["structural": salvage])
    }
    try seedFootprint(db, location: hubLocation, resources: hubStock, fetchedAt: liftoff)
}

private func seedFootprint(
    _ db: Database, location: String, resources: Int, fetchedAt: Date
) throws {
    try LocationFootprint.insert {
        LocationFootprint(
            location: location, devices: 2, resources: resources, resourceSites: 0,
            locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
        )
    }.execute(db)
}

// MARK: - The scripted seam

/// One command as it reached the wire. Only the fields these tests turn on are
/// carried; a full `CommandParams` in an expectation would assert the absence
/// of ten irrelevant fields and read as noise.
private struct SeamCommand: Equatable, Sendable, CustomStringConvertible {
    let verb: String
    let deviceCode: String

    var description: String { "\(verb) → \(deviceCode)" }
}

/// The command wire, recording only.
///
/// Every test in this file is about something the brain or the mission
/// DECLINED to do, so the assertion that matters is almost always that this
/// actor recorded nothing. It sits UNDER `CommandGovernor.liveValue` — the
/// budget gate and the per-device in-flight claim both run before anything here
/// does — and it ACCEPTS whatever reaches it, so a rail that had been deleted
/// would show up as a recorded command rather than as a rejection the mission
/// might have swallowed.
private actor RecordingSeam {
    private(set) var commands: [SeamCommand] = []
    private var opCounter = 0

    nonisolated func seam() -> CommandClient {
        var client = CommandClient.testValue
        client.dispatch = { [self] kind, deviceCode, _ in
            await record(verb: kind.rawValue, deviceCode: deviceCode)
        }
        return client
    }

    private func record(verb: String, deviceCode: String) -> CommandOutcome {
        commands.append(SeamCommand(verb: verb, deviceCode: deviceCode))
        opCounter += 1
        return .accepted(operationID: "OP-\(opCounter)")
    }
}

/// A `deviceRefresher` that answers from the local fleet table AND writes the
/// answer back with a fresh `updatedAt` — which is what `PollCoordinator` does
/// in production, and what `BrainTestSupport`'s `confirmingRefresher`
/// deliberately does not.
///
/// The difference matters here and only here: these tests run for tens of
/// virtual minutes, and `RelayRun.acquire` will not trust a hub row older than
/// `hubFreshness` (5 min). With a stand-in that never stamps the row, every
/// retry would stall `.unreachableDevice` on a perfectly reachable hub and the
/// reserve rail — the thing under test — would never be reached at all.
///
/// `answering` receives the row the database holds and returns what the SERVER
/// says about it; nil is a read that did not land.
private func reconcilingRefresher(
    _ database: any DatabaseWriter,
    reads: LockIsolated<[ConfirmRead]> = LockIsolated([]),
    answering: @escaping @Sendable (Device) async -> Device? = { $0 }
) -> DeviceRefreshClient {
    DeviceRefreshClient { code, priority in
        @Dependency(\.date) var date
        let isHigh: Bool
        switch priority {
        case .high: isHigh = true
        case .low: isHigh = false
        }
        reads.withValue { $0.append(ConfirmRead(deviceCode: code, isHigh: isHigh)) }
        let row = try? await database.read { db in
            try Device.where { $0.deviceCode.eq(code) }.fetchOne(db)
        }
        guard let row = row.flatMap({ $0 }), var fresh = await answering(row) else { return nil }
        fresh.updatedAt = date.now
        let answer = fresh
        try? await database.write { db in try Device.upsert { answer }.execute(db) }
        return answer
    }
}

/// A resolution client that records what the brain drove, performs the REAL
/// `retry`, and makes the three operator-only verbs impossible to drive
/// quietly.
///
/// `retry` calls `liveValue` rather than merely recording, for the reason
/// `BrainStallResponseTests` states: the retry budget is derived from the
/// `.resolved` timeline entries `retry` writes, so a stub that only recorded
/// would leave the budget reading zero forever and every "then escalates"
/// assertion would pass vacuously.
///
/// `skipTarget`/`pause`/`resume` stay `unimplemented` — they are the operator's
/// verbs, permanently, and a degrading brain reaching for one must fail loudly
/// wherever it happened rather than be caught by an assertion someone
/// remembered to write.
private struct Resolutions: Sendable {
    let retried = LockIsolated<[String]>([])
    let cancelled = LockIsolated<[String]>([])

    var client: DirectiveResolutionClient {
        let retried = self.retried
        let cancelled = self.cancelled
        return DirectiveResolutionClient(
            retry: { id in
                retried.withValue { $0.append(id) }
                await DirectiveResolutionClient.liveValue.retry(id)
            },
            skipTarget: unimplemented("DirectiveResolutionClient.skipTarget"),
            cancel: { id in cancelled.withValue { $0.append(id) } },
            pause: unimplemented("DirectiveResolutionClient.pause"),
            resume: unimplemented("DirectiveResolutionClient.resume"),
            clearFinished: unimplemented("DirectiveResolutionClient.clearFinished", placeholder: 0)
        )
    }
}

// MARK: - The driver

/// One virtual tick's worth of observation.
private struct Tick: Sendable {
    let report: BrainReport?
    /// Every directive id in the ledger at the end of this tick — the additivity
    /// witness (`allWritesAreAdditive`).
    let directiveIDs: Set<String>
    /// Every timeline entry id, same purpose.
    let logIDs: Set<String>
    let status: DirectiveStatus?
    let attentionReason: DirectiveAttentionReason?
}

/// A healthy actions budget, so the REAL `CommandGovernor` lets commands
/// through. `GameClient.testValue` reports `remaining: 0`, which the governor
/// correctly reads as "defer everything" — that is the governor working, not a
/// fixture to route around, so it is fed a real budget instead of replaced.
/// Every "nothing was dispatched" assertion in this file would otherwise be
/// satisfied by the governor rather than by the rail under test.
private func fundedGameClient() -> GameClient {
    var client = GameClient.testValue
    client.budget = { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil) }
    return client
}

/// Drive `count` virtual ticks of BOTH engine loops against the scripted world:
/// the brain plans (`tickBrain`), then every RUNNING directive gets one
/// executor evaluation (`evaluateOnce`) — the two loops `start()` runs side by
/// side in production. The running set is re-read after the brain plans, so a
/// run launched (or retried back to `.running`) on this tick is evaluated on
/// this tick, exactly as the supervisor would pick it up.
private func drive(
    _ database: any DatabaseWriter,
    core: DirectiveEngineCore,
    seam: RecordingSeam,
    uuid: UUIDGenerator,
    reads: LockIsolated<[ConfirmRead]>,
    censusReads: LockIsolated<Int> = LockIsolated(0),
    resolutions: Resolutions = Resolutions(),
    refresher: (@Sendable (any DatabaseWriter, LockIsolated<[ConfirmRead]>) -> DeviceRefreshClient)? = nil,
    census: Int = belowFloorStock,
    storage: InMemoryStorage,
    from start: Date,
    step: TimeInterval,
    ticks count: Int
) async -> [Tick] {
    let clock = TestClock()
    var ticks: [Tick] = []
    for index in 0..<count {
        let now = start.addingTimeInterval(Double(index) * step)
        let tick = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = uuid
            $0.continuousClock = clock
            $0.defaultInMemoryStorage = storage
            $0.deviceRefresher = refresher?(database, reads) ?? reconcilingRefresher(database, reads: reads)
            // The real governor — budget gate and per-device in-flight claim.
            $0.commandGovernor = .liveValue
            $0.gameClient = fundedGameClient()
            $0.commandClient = seam.seam()
            $0.directiveResolution = resolutions.client
            // The one scripted READ: the stockpile census the reserve rail
            // consults. `LocationsClient.refreshFootprint()` itself — the
            // persistence, the `fetchedAt` stamp — is the real one, and so is
            // the engine resolver that calls it.
            $0.locationsClient.footprint = { [censusReads] in
                censusReads.withValue { $0 += 1 }
                return [hubLocation: LocationCounts(devices: 2, resources: census)]
            }
        } operation: { () -> Tick in
            @Shared(.brainReport) var report: BrainReport?
            await core.tickBrain()
            let running = (
                try? await database.read { db in
                    try Directive
                        .where { $0.status.eq(DirectiveStatus.running) }
                        .order { $0.id }
                        .fetchAll(db)
                }
            ) ?? []
            for directive in running { await core.evaluateOnce(directiveID: directive.id) }

            let directives = (try? await database.read { db in try Directive.all.fetchAll(db) }) ?? []
            let log = (try? await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }) ?? []
            let run = directives.first { $0.kind == .relayRun }
            return Tick(
                report: report,
                directiveIDs: Set(directives.map(\.id)),
                logIDs: Set(log.map(\.id)),
                status: run?.status,
                attentionReason: run?.attentionReason
            )
        }
        ticks.append(tick)
    }
    return ticks
}

private func relayRuns(_ database: any DatabaseReader) async throws -> [Directive] {
    try await database.read { db in
        try Directive.where { $0.kind.eq(DirectiveKind.relayRun) }.order { $0.createdAt }.fetchAll(db)
    }
}

/// One brain tick with no executor beside it — the seam most of the pure-brain
/// assertions here want.
private func tickReport(
    _ database: any DatabaseWriter,
    at now: Date,
    uuid: UUIDGenerator,
    refresher: DeviceRefreshClient? = nil
) async -> BrainReport {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(now)
        $0.uuid = uuid
        $0.deviceRefresher = refresher ?? reconcilingRefresher(database)
        $0.gameClient = fundedGameClient()
    } operation: {
        await Brain(now: now).report()
    }
}

// MARK: - Clause 7: the reserve rail

/// **On concurrency, and what `.serialized` does and does not buy.** These
/// suites install `CommandGovernorClient.liveValue` — ONE process-shared
/// governor whose in-flight claim is a bare `Set<String>` keyed on device code
/// (`CommandGovernor.inFlight`). A concurrent dispatch on the same code gets
/// `.deferred(.commandInFlight)`, which for a file whose assertions are mostly
/// "nothing reached the wire" is the dangerous direction: it would make them
/// pass for entirely the wrong reason.
///
/// `.serialized` orders tests WITHIN a suite. It does not order these three
/// suites against each other, and it certainly does not order them against
/// `BrainGrowLifecycleE2ETests`, which installs the same live governor. So it
/// is not what closes the hole, and an earlier draft of this comment claimed it
/// was. What closes it is that **every device code in this file is unique to
/// this file** — `HUBDEG`, `VDEG1`, `VDEG2`, `RELDEG_1`, `RELDEG_S`, `RDEG_A`,
/// none of which appears in any other suite — so no other test can hold a claim
/// on a code these tests dispatch at. `.serialized` is kept for the narrower
/// property it does provide: a stable order within each suite.
@Suite("Brain — bounded blast radius: the reserve rail", .serialized)
struct BrainReserveRailDegradationTests {

    /// **The headline, and the rail Task 25's lifecycle gate never loads.**
    ///
    /// Same world, same real stack, one fact changed: the hub holds 34,000 units
    /// against `BrainCeiling.aggregateSpendFloor`'s 35,078. The brain still
    /// ranks VEGA and still launches a Relay Run — it is a selector, and the
    /// rail lives at the ENACTMENT layer where the spend actually is — and then
    /// `RelayRun.acquire` refuses to dispatch the print.
    ///
    /// Four separate things are asserted, and each of them can fail on its own:
    ///
    ///   1. **The print never went out.** Not "the run stalled" — the actual
    ///      command list, empty. This is the assertion that fails outright if
    ///      the rail is disarmed.
    ///   2. **No thrash.** ONE run for fifty virtual minutes of ticks, and the
    ///      brain's auto-retry spent exactly its budget (3) rather than one per
    ///      tick.
    ///   3. **No budget burn.** The authoritative `.high` reads and the census
    ///      refreshes are both counted exactly. A rail that re-fired every tick
    ///      would show 600 of them.
    ///   4. **It escalates.** The run ends `.needsAttention` carrying
    ///      `.printStockShort`, and the brain's own decision ends `.stall` —
    ///      surfaced AND escalated, which is what a human needs to see.
    @Test func theReserveRailVetoesThePrintAndTheBrainIdlesInsteadOfThrashing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedDegradationWorld(db, hubStock: belowFloorStock) }
        let seam = RecordingSeam()
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let reads = LockIsolated<[ConfirmRead]>([])
        let censusReads = LockIsolated(0)
        let resolutions = Resolutions()
        let uuid = UUIDGenerator.incrementing

        // Fifty virtual minutes at the engine's own 5-second cadence. Long
        // enough to cover the whole retry episode — attempts land at roughly
        // t, t+15 min and t+30 min (`Brain.retryInterval`), with escalation
        // following the third — and long enough that a per-tick loop would be
        // unmissable in the counts below.
        let ticks = await drive(
            database, core: core, seam: seam, uuid: uuid, reads: reads,
            censusReads: censusReads, resolutions: resolutions,
            storage: InMemoryStorage(), from: liftoff, step: 5, ticks: 600
        )

        // 1. THE RAIL FIRED. No print — no command of any kind — reached the
        //    wire, over six hundred ticks, with a healthy actions budget and a
        //    seam that accepts everything.
        #expect(
            await seam.commands.isEmpty,
            "the reserve rail vetoes BEFORE the dispatch: nothing may reach the wire"
        )

        // 2. NO THRASH. One launch, however many ticks ran, and a retry count
        //    that is the budget rather than the tick count.
        let runs = try await relayRuns(database)
        #expect(runs.count == 1, "one launch for one target, and the stalled run keeps its carrier")
        let launched = try #require(runs.first)
        #expect(
            resolutions.retried.value == Array(repeating: launched.id, count: Brain.retryBudget),
            "exactly the retry budget's worth of auto-retries, spread over the interval, then it stops"
        )
        #expect(resolutions.cancelled.value.isEmpty, "a resource shortage is not a reason to cancel a run")

        // 3. NO BUDGET BURN. Both live-API counters, exactly — and the exact
        //    figures are the evidence, not a ceiling somebody guessed at.
        //
        //    THREE authoritative reads and TWO census refreshes for fifty
        //    virtual minutes of ticking. A rail that re-judged per tick would
        //    show six hundred of each.
        //
        //    Both are LIST/VALUE equalities over the whole run, not ceilings:
        //    a 601st read, a `.low` poll sneaking in, or a read of a device
        //    nobody named all fail. And because they cover the whole run, the
        //    ~450 ticks that follow the third retry's escalation are pinned
        //    too — zero further reads, zero further commands, on a run that is
        //    now permanently escalated. That tail is the actual proof that the
        //    cost tracks the retry budget rather than the clock.
        //
        //    The `.high` reads are the brain's one confirm of the carrier at
        //    launch, plus one hub read for each of the SECOND and THIRD
        //    retries. The first retry buys nothing: it fires the moment the run
        //    stalls (there is no `.resolved` entry to space it from), so it
        //    re-enters `acquire` while the hub row and the census are both
        //    still inside their own freshness windows — `hubFreshness` is 5 min
        //    and `SalvageRun.relayPollInterval` 60 s, against a stall that
        //    happened seconds ago. It re-judges the rows it already has and
        //    vetoes again for free. The later two land 15 and 30 virtual
        //    minutes out, past both windows, so each pays for exactly one hub
        //    read and one census refresh before re-judging.
        //
        //    That is the shape a bounded degradation should have: the cost
        //    tracks the RETRY BUDGET, never the clock.
        #expect(
            reads.value == [ConfirmRead(deviceCode: "VDEG1", isHigh: true)]
                + Array(
                    repeating: ConfirmRead(deviceCode: "HUBDEG", isHigh: true),
                    count: Brain.retryBudget - 1
                ),
            "one confirm-read for the launch, one hub read per SPACED retry — and nothing per-tick"
        )
        #expect(
            censusReads.value == Brain.retryBudget - 1,
            "one census refresh per spaced retry: the rail re-reads before re-judging, and only then"
        )

        // 4. IT ESCALATED — and the escalation is what the last tick reports.
        #expect(launched.status == .needsAttention)
        #expect(launched.attentionReason == .printStockShort)
        #expect(launched.step == RelayRun().firstStep, "the brain never hand-edits a stalled run's step")
        #expect(launched.targets == [target], "…nor its targets")
        let last = try #require(ticks.last)
        #expect(last.report?.decision == .stall(.printStockShort))
    }

    /// **The positive control, and the reason the test above cannot be passing
    /// for an unrelated reason.** One fact changed — the hub census reads
    /// 200,000 instead of 34,000 — and the same stack, over three ticks,
    /// dispatches the print.
    ///
    /// Without this, "no command reached the wire" is equally satisfied by a
    /// world where the brain never launched, the governor deferred everything,
    /// or the seam was never wired up.
    @Test func aWorldAboveTheFloorPrintsWithTheIdenticalStack() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedDegradationWorld(db, hubStock: aboveFloorStock) }
        let seam = RecordingSeam()
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let uuid = UUIDGenerator.incrementing

        _ = await drive(
            database, core: core, seam: seam, uuid: uuid, reads: LockIsolated([]),
            census: aboveFloorStock, storage: InMemoryStorage(), from: liftoff, step: 5, ticks: 3
        )

        #expect(
            await seam.commands == [SeamCommand(verb: "print", deviceCode: "HUBDEG")],
            "above the floor the identical stack prints — so the veto above is the rail, not the fixture"
        )
        let run = try #require(try await relayRuns(database).first)
        #expect(run.attentionReason == nil, "nothing stalls on a funded world")
    }

    /// The rail's veto, as the operator sees it in the why-view's feed: on the
    /// same world the test above drove to a real veto, the brain's own report
    /// reads BELOW FLOOR — so the card and the rail cannot tell an operator two
    /// different stories about the same world.
    ///
    /// **This test does not drive the rail**, and its name says so: it reads the
    /// MIRROR (`BrainLimits.hubStockStanding`) on a world the test above proved
    /// the rail vetoes. The mirror↔rail agreement itself — every combination of
    /// stock and age, including the exact `hubFreshness` boundary — is pinned
    /// separately by `BrainCeilingTests.hubStockStandingAgreesWithTheRailItMirrors`.
    /// What is added here is that the two are pointed at the same WORLD, which
    /// neither of those tests establishes on its own.
    ///
    /// `BrainLimits.hubStockStanding` is a deliberate mirror of
    /// `RelayRun.printStockIsShort` (they read different shapes and so cannot
    /// share an implementation); `hubStockStandingAgreesWithTheRailItMirrors`
    /// pins the two against each other, and this pins the mirror against a world
    /// the rail really did veto.
    @Test func theWhyViewFeedReadsBelowFloorOnTheWorldTheRailVetoes() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedDegradationWorld(db, hubStock: belowFloorStock) }

        let report = await tickReport(database, at: liftoff, uuid: .incrementing)

        #expect(report.limits.hubStock == belowFloorStock)
        #expect(report.limits.spendFloor == BrainCeiling.aggregateSpendFloor)
        #expect(
            report.limits.hubStockStanding(at: liftoff) == .belowFloor,
            "the feed must say what the rail did — printing vetoed, not comfortable headroom"
        )
    }
}

// MARK: - Clause 7: bounded blast radius

/// `.serialized`, and unique device codes — see the concurrency note on
/// `BrainReserveRailDegradationTests` above for which of the two is load-bearing.
@Suite("Brain — bounded blast radius: commitments and writes", .serialized)
struct BrainBlastRadiusTests {

    /// **`Brain.commitBlocker`'s third guard, which had no test anywhere in this
    /// package.** `BrainConfirmFreshTests` loads the carrier arm and the target
    /// arm; the `inFlightSources` arm — "a relay another run is already fetching
    /// is not offered twice" — was checked only on the SELECTION side
    /// (`BrainReclaimSourcingTests.aSourceAnotherRunIsAlreadyFetchingIsNotSelectedTwice`),
    /// never at commit time.
    ///
    /// The race is the one the guard is written for: the brain has ranked, has
    /// chosen `RDEG_A` as its reclaim source, and has taken its `.high` confirm-read
    /// — and a second Relay Run claiming `RDEG_A` lands before the insert opens.
    /// The racing row is driven off the `uuid` generator, the one deterministic
    /// seam between the confirm-read and the write transaction; `DatabaseWriter`
    /// commits it there and then, so by the time the brain's own transaction
    /// opens the collision is already on disk. Only a re-check taken INSIDE that
    /// transaction can see it.
    ///
    /// Losing this race is the expensive one: two carriers converge on one
    /// relay, the second finds it stowed aboard somebody else, and the mesh has
    /// lost a node for one grow instead of two. The gate DEFERS the whole tick
    /// rather than falling back to a print — its contract is to let the tick's
    /// decision through or stop it, never to substitute a resource-spending one.
    ///
    /// **Scope, stated so nobody reads more into it.** This pins the guard's
    /// LOGIC, not its PLACEMENT. The racing row commits at `uuid()`, which is
    /// strictly before `database.write` opens, so a re-check hoisted just
    /// outside the transaction would pass this test too. The in-transaction
    /// placement — the thing `launch`'s doc argues for at length — is not
    /// pinned here, and arguably cannot be pinned deterministically: it would
    /// need a writer that interleaves INSIDE GRDB's serialized write queue,
    /// which is precisely what that queue exists to prevent. The same limit
    /// applies to `BrainConfirmFreshTests.anOperatorLaunchAfterTheConfirmReadIs`
    /// `StillCaught`, which races the same seam for the carrier arm.
    @Test func aRacingClaimOnTheSameSpareRelayIsRefusedAtCommitTime() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedReclaimableWorld(db) }
        let racing = UUIDGenerator {
            try? database.write { db in
                // A DIFFERENT carrier and a DIFFERENT target, so neither of
                // `commitBlocker`'s other two guards can fire: the only thing
                // this row collides on is `sourceRelayCode`.
                try seedRelayRun(
                    db, id: "OTHER", deviceCode: "VDEG2", targets: ["ELSEWHERE"], sourceRelayCode: "RDEG_A"
                )
            }
            return UUID(uuidString: "00000000-0000-0000-0000-0000000000FD")!
        }

        let report = await tickReport(database, at: liftoff, uuid: racing)

        #expect(
            report.decision == .idle(reason: "deferred — relay RDEG_A already claimed on confirm"),
            "the tick must defer wholesale, not fall back to a 370-unit print"
        )
        let runs = try await relayRuns(database)
        #expect(runs.map(\.id) == ["OTHER"], "no second run may claim RDEG_A")
        #expect(
            report.prune?.reclaimed == nil,
            "a deferred tick reclaimed nothing, so the why-view must not say it did"
        )
    }

    /// The positive control for the guard above: the identical world with no
    /// racing claim launches, and sources itself from `RDEG_A`.
    ///
    /// Without it, "no second run was written" is equally satisfied by a world
    /// in which the brain would never have reclaimed anything.
    @Test func theSameWorldWithoutTheRaceReclaimsR_A() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedReclaimableWorld(db) }

        let report = await tickReport(database, at: liftoff, uuid: .incrementing)

        guard case .dispatch = report.decision else {
            Issue.record("expected a launch, got \(report.decision)")
            return
        }
        let run = try #require(try await relayRuns(database).first)
        #expect(run.sourceRelayCode == "RDEG_A", "unraced, this world really does source from RDEG_A")
        #expect(report.prune?.reclaimed?.deviceCode == "RDEG_A")
    }

    /// **Reclaim never strands live value, and the guard is the confirm-read.**
    ///
    /// The brain plans off a best-effort `WorldView`: here it names `RDEG_A` as a
    /// spare relay to reclaim, on the strength of a device row that is a full
    /// day old. By the time the run evaluates, the authoritative read says the
    /// relay is no longer the deployed, `relaying` relay prune assessed —
    /// somebody got there first.
    ///
    /// The run refuses. It does NOT `deactivate` on the stale row, and — the
    /// more tempting mistake — it does not fall back to printing 370 units the
    /// plan explicitly declined to spend. It stalls, which is exactly clause 7's
    /// worst case: an operator-resolvable halt, with the mesh intact.
    ///
    /// The assertion is on the WIRE, not on the step: zero commands. A run that
    /// deactivated a live relay on stale evidence would show one here.
    @Test func aStaleSourceRowNeverAuthorisesTearingARelayDown() async throws {
        let database = try GameDatabase.bootstrap()
        // The source's row is stamped a DAY before the tick — far past
        // `RelayRun.reclaimFreshness` (5 min), so nothing may be concluded from
        // it without an authoritative read.
        try await database.write { db in
            try seedReclaimableWorld(db, sourceUpdatedAt: liftoff.addingTimeInterval(-86_400))
        }
        let seam = RecordingSeam()
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let reads = LockIsolated<[ConfirmRead]>([])
        let uuid = UUIDGenerator.incrementing

        // The server's answer for the source: it is already down. Everything
        // else answers unchanged, so this is the ONE fact the stale row got
        // wrong.
        let refresher: @Sendable (any DatabaseWriter, LockIsolated<[ConfirmRead]>) -> DeviceRefreshClient = {
            db, reads in
            reconcilingRefresher(db, reads: reads) { device in
                guard device.deviceCode == "RDEG_A" else { return device }
                var down = device
                down.status = "inactive"
                return down
            }
        }

        _ = await drive(
            database, core: core, seam: seam, uuid: uuid, reads: reads,
            refresher: refresher, storage: InMemoryStorage(),
            from: liftoff, step: 5, ticks: 3
        )

        #expect(
            await seam.commands.isEmpty,
            "no deactivate, no travel, no print — the run refuses to act on a stale row"
        )
        let run = try #require(try await relayRuns(database).first)
        #expect(run.sourceRelayCode == "RDEG_A", "the plan hint is left intact for the operator to judge")
        #expect(run.status == .needsAttention, "an operator-resolvable stall is the worst case")
        #expect(run.attentionReason == .unreachableDevice)
        #expect(
            reads.value.contains(ConfirmRead(deviceCode: "RDEG_A", isHigh: true)),
            "the refusal is EARNED by an authoritative read, not assumed from the row's age"
        )
        // The run did nothing TO the relay. Its row now reads `inactive`
        // because the authoritative read reconciled the server's own answer
        // back into the fleet — that is the world having moved, not us moving
        // it — but it is stowed aboard nothing and standing exactly where it
        // was. Nothing was stranded, and nothing was torn down.
        let relay = try #require(
            await database.read { db in try Device.where { $0.deviceCode.eq("RDEG_A") }.fetchOne(db) }
        )
        #expect(relay.stowedInDeviceCode == nil, "no stow — the reclaim never got that far")
        #expect(relay.location == "DEADEND-1", "and it never moved")
    }

    /// **All writes are additive.** Across the whole reserve-rail degradation
    /// run — a launch, three auto-retries, three stalls and an escalation — the
    /// set of directive ids and the set of timeline entry ids only ever GROW.
    ///
    /// This is the clause-7 property that is easiest to lose quietly: a brain
    /// that "tidied up" a stalled run by deleting it, or an executor that
    /// rewrote a timeline entry rather than appending one, would leave the
    /// operator's ledger with holes in it and every other assertion in this file
    /// still green. Checked tick-over-tick rather than start-to-end, so a row
    /// that vanished and was re-created would still fail.
    @Test func allWritesAreAdditive() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedDegradationWorld(db, hubStock: belowFloorStock) }
        let seam = RecordingSeam()
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let uuid = UUIDGenerator.incrementing

        let ticks = await drive(
            database, core: core, seam: seam, uuid: uuid, reads: LockIsolated([]),
            storage: InMemoryStorage(), from: liftoff, step: 60, ticks: 60
        )

        for (index, pair) in zip(ticks, ticks.dropFirst()).enumerated() {
            #expect(
                pair.1.directiveIDs.isSuperset(of: pair.0.directiveIDs),
                "tick \(index + 1) lost a directive row — the ledger is append-only"
            )
            #expect(
                pair.1.logIDs.isSuperset(of: pair.0.logIDs),
                "tick \(index + 1) lost a timeline entry — the log is append-only"
            )
        }
        // …and the run really did go through the whole stall episode, so the
        // superset checks above ran over a ledger that was genuinely changing
        // rather than over sixty identical snapshots.
        let first = try #require(ticks.first)
        let last = try #require(ticks.last)
        #expect(last.attentionReason == .printStockShort)
        #expect(
            last.logIDs.count > first.logIDs.count,
            "the timeline grew — otherwise every superset check above is vacuous"
        )
    }
}

// MARK: - Clause 6: safe degradation

/// `.serialized`, and unique device codes — see the concurrency note on
/// `BrainReserveRailDegradationTests` above for which of the two is load-bearing.
@Suite("Brain — safe degradation", .serialized)
struct BrainSafeDegradationTests {

    /// **Unknown is left alone.** The world is identical to the one that ranks
    /// VEGA first — same star, same distance, same mesh, same hub, same free
    /// carrier — except that nothing has assayed VEGA. No salvage totals, no
    /// belts, no event.
    ///
    /// The brain ranks nothing and launches nothing. It does not guess, does not
    /// send a carrier to look, and does not treat "we have no value data" as
    /// "there is no value": survey is a separate goal with its own mission, and
    /// `tendMesh` meshes toward KNOWN value by construction
    /// (`brain-tendmesh-worthiness`).
    ///
    /// The two halves are asserted TOGETHER, in one test, because either alone
    /// is worthless: a brain that ranked nothing ever would pass the first, and
    /// one that ranked everything would pass the second.
    @Test func aSystemWithNoValueDataYieldsNoTargetAndOneWithValueDoesGetOne() async throws {
        let unknown = try GameDatabase.bootstrap()
        try await unknown.write { db in
            try seedDegradationWorld(db, hubStock: aboveFloorStock, salvage: nil)
        }
        let known = try GameDatabase.bootstrap()
        try await known.write { db in
            try seedDegradationWorld(db, hubStock: aboveFloorStock, salvage: 3_200)
        }

        let unknownReport = await tickReport(unknown, at: liftoff, uuid: .incrementing)
        let knownReport = await tickReport(known, at: liftoff, uuid: .incrementing)

        #expect(unknownReport.ranked.isEmpty, "no value data ⇒ no grow candidate")
        #expect(unknownReport.decision == .idle(reason: "no grow or prune work"))
        #expect(
            try await relayRuns(unknown).isEmpty,
            "an unknown neighbourhood is left alone — nothing is written, nothing is spent"
        )

        #expect(knownReport.ranked.map(\.firstHop) == [target], "the SAME world, plus one assay, ranks")
        guard case let .dispatch(goal, _) = knownReport.decision else {
            Issue.record("expected the assayed world to launch, got \(knownReport.decision)")
            return
        }
        #expect(goal.target == target)
    }

    /// **A transient failure defers, and a deferred tick writes nothing and
    /// spends nothing.**
    ///
    /// The confirm-read — the brain's one authoritative look at the carrier
    /// before an irreversible commitment — comes back nil for twenty
    /// consecutive ticks. `DeviceRefreshClient.testValue` is INERT (nil, not
    /// `unimplemented`), which is exactly the shape of a real transient: the
    /// read simply did not land.
    ///
    /// Every one of those ticks defers with its own distinct reason ("could not
    /// be confirmed", never "unavailable" — an operator has to be able to tell
    /// an API problem from a carrier that was taken), writes NO row, and
    /// dispatches NO command. Then the read starts landing and the very next
    /// tick launches, exactly once — the deferral was never remembered, which is
    /// clause 2 and is what makes this degradation SAFE rather than sticky.
    ///
    /// **What this proves about SPEND, stated exactly, because the obvious
    /// reading of it is too generous.** A deferred tick writes nothing and
    /// dispatches nothing — that is proven outright. It does NOT prove the
    /// deferral path is cheap: the read count below is one `.high` read per
    /// tick, which at the engine's 5-second cadence is **12 authoritative reads
    /// per minute, sustained for as long as the API stays down**, with no
    /// backoff and — by clause 2 — no memory of the last refusal.
    ///
    /// That is a deliberate, documented trade (`Brain.confirmCarrier`'s own doc:
    /// "the ceiling is one `.high` read per tick (12/min, for ONE device) …
    /// the alternative is remembering the refusal, which is state between ticks
    /// (clause 2), and the same window would otherwise have the brain
    /// committing blind"). The assertion below pins that ceiling rather than
    /// endorsing it: a build that started reading twice per tick, or polling
    /// `.low` beside it, fails here.
    ///
    /// **So bounded read cost is proven for the STALL-RETRY path only** — by
    /// `theReserveRailVetoesThePrintAndTheBrainIdlesInsteadOfThrashing` (three
    /// reads for six hundred ticks) and `autoRetriesAreSpacedByTheRetryInterval`
    /// (the 15-minute floor between attempts). The transient-deferral path has
    /// no backoff at all, and nothing in this file should be read as claiming
    /// otherwise.
    @Test func aTransientConfirmFailureDefersEveryTickAndWritesNothingUntilItClears() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedDegradationWorld(db, hubStock: aboveFloorStock) }
        let seam = RecordingSeam()
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let reads = LockIsolated<[ConfirmRead]>([])
        let uuid = UUIDGenerator.incrementing
        let storage = InMemoryStorage()

        let failing: @Sendable (any DatabaseWriter, LockIsolated<[ConfirmRead]>) -> DeviceRefreshClient = {
            db, reads in reconcilingRefresher(db, reads: reads) { _ in nil }
        }
        let deferred = await drive(
            database, core: core, seam: seam, uuid: uuid, reads: reads,
            refresher: failing, census: aboveFloorStock, storage: storage,
            from: liftoff, step: 5, ticks: 20
        )

        #expect(
            deferred.allSatisfy {
                $0.report?.decision == .idle(reason: "deferred — carrier VDEG1 could not be confirmed")
            },
            "every tick defers, with the reason that says the read failed rather than that VDEG1 was taken"
        )
        // **Scoped to the GROW decision, and it has to be.** A deferred tick
        // launches no Relay Run and gives no order to the carrier it could not
        // confirm — that is the clause. It is NOT "the tick writes nothing at
        // all" any more, because restock lives on the hub and prints against
        // demand whether or not a carrier is available. That decoupling is the
        // point of restock rather than a leak in this rail: the printer being
        // idle was the second thing standing between the brain and an
        // unattended mesh, and a carrier the API cannot confirm is exactly when
        // you want the spares already made.
        #expect(try await relayRuns(database).isEmpty, "a deferred tick launches no run")
        #expect(
            deferred.allSatisfy { $0.attentionReason == nil },
            "…and leaves nothing for a human to answer"
        )
        let carrierCommands = await seam.commands.filter { $0.deviceCode == "VDEG1" }
        #expect(carrierCommands.isEmpty, "…and gives the unconfirmed carrier no orders")
        #expect(
            await seam.commands.allSatisfy { $0.verb == OperationKind.print.rawValue },
            "the only thing moving is the hub's printer, which needs no carrier"
        )
        // Implied by the exact-equality check above as far as the STRING goes —
        // kept because it pins something that equality cannot: that the reason
        // the brain emits is one `BrainDecision.isDeferral` actually recognises.
        // Those are two separate pieces of production (`deferralPrefix` and the
        // accessor), and the why-view's whole idle/deferred split hangs off the
        // accessor, so a drift between them must fail here rather than in a
        // screenshot.
        #expect(
            deferred.allSatisfy { $0.report?.decision.isDeferral == true },
            "a deferral is its own state — it must not read as idle-with-nothing-to-do"
        )
        #expect(
            reads.value == Array(repeating: ConfirmRead(deviceCode: "VDEG1", isHigh: true), count: 20),
            "one confirm-read per tick and nothing else: the gate fires on commitment, not on a poll"
        )

        // …and then the read lands.
        let recovered = await drive(
            database, core: core, seam: seam, uuid: uuid, reads: LockIsolated([]),
            census: aboveFloorStock, storage: storage,
            from: liftoff.addingTimeInterval(100), step: 5, ticks: 2
        )
        let runs = try await relayRuns(database)
        #expect(runs.count == 1, "the very next healthy tick launches — once, not twenty times over")
        #expect(runs.first?.targets == [target])
        guard case .dispatch = try #require(recovered.first).report?.decision else {
            Issue.record("expected the recovered tick to dispatch")
            return
        }
    }

    /// **Idle-surfaced-not-escalated and stall-surfaced-and-escalated must not
    /// look alike** — clause 6's sharpest requirement, driven end-to-end
    /// through the real stack in both worlds rather than asserted over
    /// hand-built reports.
    ///
    /// The distinction is checked on the three things that carry it:
    ///
    ///   1. **The decision the brain publishes.** `.idle` vs `.stall`, which is
    ///      the exact discriminator `BrainWhy.from`'s exhaustive switch reads —
    ///      `isEscalated` is false for `.idle`/`.dispatch` and true for `.stall`
    ///      alone, pinned by `BrainWhyViewTests.theFourGateStatesAllReadDifferently`
    ///      over all four gate shapes (and `aDeferralReadsAsItsOwnGateNotAsAn`
    ///      `OrdinaryIdle` for the third). Those drive SYNTHETIC reports; this
    ///      one proves the real brain produces the two inputs they distinguish.
    ///   2. **Neither is a DEFERRAL.** A deferred tick is normal operation and
    ///      must not creep into either bucket.
    ///   3. **The ledger.** The idle world surfaces NOTHING — no
    ///      `.needsAttention` row for a human to find — while the stuck world
    ///      leaves exactly one, carrying its reason. A brain that reported a
    ///      stall it had not surfaced, or surfaced a run it reported as calm,
    ///      fails here.
    @Test func anIdleBrainAndAStuckBrainDoNotLookAlike() async throws {
        // The idle world: everything healthy, nothing worth doing.
        let idleWorld = try GameDatabase.bootstrap()
        try await idleWorld.write { db in
            try seedDegradationWorld(db, hubStock: aboveFloorStock, salvage: nil)
        }
        let idle = await tickReport(idleWorld, at: liftoff, uuid: .incrementing)

        // The stuck world: the reserve rail below floor, driven until the retry
        // budget is spent and the run is left for a human.
        let stuckWorld = try GameDatabase.bootstrap()
        try await stuckWorld.write { db in try seedDegradationWorld(db, hubStock: belowFloorStock) }
        let stuckTicks = await drive(
            stuckWorld, core: DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5)),
            seam: RecordingSeam(), uuid: .incrementing, reads: LockIsolated([]),
            storage: InMemoryStorage(), from: liftoff, step: 60, ticks: 45
        )
        let lastStuckTick = try #require(stuckTicks.last)
        let stuck = try #require(lastStuckTick.report)

        // 1. The decisions, and the discriminator the why-view switches on.
        #expect(idle.decision == .idle(reason: "no grow or prune work"))
        #expect(stuck.decision == .stall(.printStockShort))
        #expect(idle.decision != stuck.decision)

        // 2. Neither is a deferral.
        #expect(!idle.decision.isDeferral)
        #expect(!stuck.decision.isDeferral)

        // 3. The ledger agrees with each of them.
        let idleAttention = try await needingAttention(idleWorld)
        #expect(idleAttention.isEmpty, "a calm brain surfaces nothing for a human to resolve")
        let stuckAttention = try await needingAttention(stuckWorld)
        #expect(stuckAttention.map(\.attentionReason) == [.printStockShort],
                "a stuck brain leaves exactly one surfaced run, carrying its reason")
    }

    /// The backoff itself, read off the timeline the retries actually wrote.
    ///
    /// "Defer with backoff" is only a real property if the gaps are real: three
    /// auto-retries fired one tick apart would spend the whole budget inside a
    /// single print's duration and escalate a shortage that a delivery cycle
    /// would have cleared. `Brain.retryInterval` is 15 minutes and this is where
    /// the driven run is held to it.
    ///
    /// The first attempt is deliberately NOT spaced: at the first stall there is
    /// no `.resolved` entry to measure from, so it fires immediately. Only the
    /// gaps BETWEEN attempts are the backoff.
    @Test func autoRetriesAreSpacedByTheRetryInterval() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedDegradationWorld(db, hubStock: belowFloorStock) }
        let resolutions = Resolutions()

        _ = await drive(
            database, core: DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5)),
            seam: RecordingSeam(), uuid: .incrementing, reads: LockIsolated([]),
            resolutions: resolutions, storage: InMemoryStorage(),
            from: liftoff, step: 60, ticks: 45
        )

        let resolved = try await database.read { db in
            try DirectiveLogEntry
                .where { $0.kind.eq(DirectiveLogKind.resolved) }
                .order { $0.occurredAt }
                .fetchAll(db)
        }
        #expect(resolved.count == Brain.retryBudget, "the budget, spent and no more")
        let gaps = zip(resolved, resolved.dropFirst()).map {
            $1.occurredAt.timeIntervalSince($0.occurredAt)
        }
        #expect(
            gaps.allSatisfy { $0 >= Brain.retryInterval },
            "every gap between attempts clears the configured floor — gaps were \(gaps)"
        )
        // …and an INDEPENDENT anchor, because the line above compares the
        // observed gaps against the very constant that produces them: set
        // `retryInterval` to zero and it still passes, which is exactly the
        // test-that-cannot-fail this suite exists to avoid. `RelayRun
        // .hubFreshness` is the information floor `Brain.retryInterval`'s own
        // doc derives from — below it a retry re-reads numbers the run already
        // considers current and is STRUCTURALLY incapable of a different
        // answer, so it can only burn an attempt. A backoff that does not
        // clear it is not a backoff.
        #expect(
            gaps.allSatisfy { $0 > RelayRun.hubFreshness },
            "…and clears the freshness floor below which a retry cannot learn anything — gaps were \(gaps)"
        )
        #expect(gaps.count == Brain.retryBudget - 1)
    }
}

// MARK: - Shared world helpers

/// Every directive currently surfaced for a human.
private func needingAttention(_ database: any DatabaseReader) async throws -> [Directive] {
    try await database.read { db in
        try Directive
            .where { $0.status.eq(DirectiveStatus.needsAttention) }
            .order { $0.id }
            .fetchAll(db)
    }
}

/// A world in which the brain will source its grow from a RECLAIM rather than a
/// print: `SOL` meshed and hosting the hub, `VEGA` 5 ly out holding the value,
/// and a spare relay `RDEG_A` at `DEADEND` 7.07 ly from the plant site — inside
/// `Brain.reclaimRangeLY` (15 ly).
///
/// `DEADEND` is genuinely spare rather than declared so: a meshed, SURVEYED
/// system with no value, no fleet and no replicant, so the anchor→target
/// path-union misses it. `VDEG1` hosts a replicant, without which the brain
/// refuses to send it on a reclaim at all (`ftl-authority-rule` rule 1) and
/// every test here would pass by printing.
///
/// `VDEG2` exists so the racing row can name a carrier that is not the one under
/// test — the point of that test is that ONLY `sourceRelayCode` collides.
private func seedReclaimableWorld(
    _ db: Database, sourceUpdatedAt: Date = liftoff
) throws {
    try seedRelay(db, code: "RELDEG_S", location: "SOL", updatedAt: liftoff)
    try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
    try seedSystemDetail(db, system: "SOL", scanned: true)
    try seedPrintHub(db, code: "HUBDEG", location: hubLocation, updatedAt: liftoff)
    try seedDevice(db, code: "VDEG1", type: "heaven_vessel", location: hubLocation, updatedAt: liftoff)
    try seedDevice(db, code: "VDEG2", type: "heaven_vessel", location: hubLocation, updatedAt: liftoff)
    try seedReplicant(db, code: "REP0", star: "SOL", hostedDeviceCode: "VDEG1")

    try seedStar(db, designation: target, x: 5, y: 0, z: 0)
    try seedSalvageAssay(db, id: "SITE-\(target)", system: target, totals: ["structural": 3_200])

    try seedStar(db, designation: "DEADEND", x: 0, y: 0, z: -5)
    try seedSystemDetail(db, system: "DEADEND", scanned: true)
    try seedRelay(db, code: "RDEG_A", location: "DEADEND-1", updatedAt: sourceUpdatedAt)

    try seedFootprint(db, location: hubLocation, resources: aboveFloorStock, fetchedAt: liftoff)
}
