//
//  BrainDegradationTests.swift
//  Replicould — DirectiveEngine
//
//  Loads the two rails the lifecycle e2e traverses but never fires: the reserve
//  rail (that suite seeds 999,999 units, so every print is permitted) and
//  `commitBlocker`'s `inFlightSources` arm (nothing there races). Only the wire,
//  the footprint read and the device refresher are faked; `Brain`, `RelayRun`,
//  `DirectiveExecutor` and the governor are real. `uuid` is bound ONCE per test —
//  `incrementing` is a computed property, so re-binding per tick mints the same id
//  and makes every row-count assertion incapable of failing.
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

/// Rows are stamped with this rather than the epoch: `RelayRun.acquire` refuses a
/// hub row older than `hubFreshness`, so an epoch-stamped fleet would spend every
/// test in a refresh-then-stall loop instead of reaching the rail under test.
private let liftoff = Date(timeIntervalSince1970: 2_000_000)

/// Inside the meshed `SOL` system, which makes it a recognised theatre.
private let hubLocation = "SOL-3"

private let target = "VEGA"

/// Below `aggregateSpendFloor` but deliberately NOT zero — the rail must veto on a
/// world plainly holding resources, because what it protects is the reserve rather
/// than the last unit.
private let belowFloorStock = 34_000

private let aboveFloorStock = 200_000

/// The smallest world ranking one grow candidate. `salvage` is a parameter so the
/// unknown-value case can remove the value data and change nothing else.
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

/// The command wire, recording only. Sits UNDER `CommandGovernor.liveValue` and
/// ACCEPTS whatever reaches it, so a deleted rail shows up as a recorded command
/// rather than as a rejection the mission might have swallowed.
private actor RecordingSeam {
    private(set) var commands: [SeamCommand] = []
    private var opCounter = 0

    nonisolated func seam() -> CommandClient {
        var client = CommandClient.testValue
        let body: @Sendable (OperationKind, String, CommandParams) async -> CommandOutcome = { [self] kind, deviceCode, _ in
            await record(verb: kind.rawValue, deviceCode: deviceCode)
        }
        client.dispatch = body
        client.dispatchOwned = { kind, deviceCode, params, _ in await body(kind, deviceCode, params) }
        return client
    }

    private func record(verb: String, deviceCode: String) -> CommandOutcome {
        commands.append(SeamCommand(verb: verb, deviceCode: deviceCode))
        opCounter += 1
        return .accepted(operationID: "OP-\(opCounter)")
    }
}

/// Answers from the local fleet table AND writes back a fresh `updatedAt`, as
/// `PollCoordinator` does and `confirmingRefresher` deliberately does not. These
/// tests run for tens of virtual minutes, so without the stamp every retry would
/// stall `.unreachableDevice` on a reachable hub and never reach the rail under
/// test. `answering` returns what the SERVER says; nil is a read that did not land.
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

/// Records what the brain drove and performs the REAL `retry` — the budget is
/// derived from the `.resolved` entries `retry` writes, so a stub that only
/// recorded would leave it reading zero and every "then escalates" assertion would
/// pass vacuously. `skipTarget`/`pause`/`resume` stay `unimplemented` so a brain
/// reaching for an operator verb fails loudly where it happened.
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

/// A healthy actions budget, so the REAL governor lets commands through.
/// `GameClient.testValue` reports `remaining: 0`, which the governor correctly
/// reads as "defer everything" — leaving it would satisfy every "nothing was
/// dispatched" assertion here by the governor rather than by the rail under test.
private func fundedGameClient() -> GameClient {
    var client = GameClient.testValue
    client.budget = { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil) }
    return client
}

/// Drive `count` virtual ticks of BOTH engine loops: the brain plans, then every
/// running directive gets one executor evaluation. The running set is re-read
/// after the brain plans, so a run launched on this tick is evaluated on it.
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

/// The live governor's in-flight claim is keyed on device code, and a concurrent
/// dispatch on the same code defers — which would make this file's "nothing
/// reached the wire" assertions pass for the wrong reason. What prevents it is
/// that **every device code here is unique to this file**; `.serialized` only
/// orders tests within a suite, not across them.
@Suite("Brain — bounded blast radius: the reserve rail", .serialized)
struct BrainReserveRailDegradationTests {

    /// One fact changed against the lifecycle e2e: the hub holds 34,000 units
    /// against a 35,078 floor. The brain still ranks VEGA and still launches — it
    /// is a selector, and the rail lives at the ENACTMENT layer — and then
    /// `acquire` refuses the print. Asserts four independently-failing things: the
    /// command list is empty, one run for fifty virtual minutes, the live-API
    /// counters are exact, and it ends escalated.
    @Test func theReserveRailVetoesThePrintAndTheBrainIdlesInsteadOfThrashing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedDegradationWorld(db, hubStock: belowFloorStock) }
        let seam = RecordingSeam()
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let reads = LockIsolated<[ConfirmRead]>([])
        let censusReads = LockIsolated(0)
        let resolutions = Resolutions()
        let uuid = UUIDGenerator.incrementing

        // Fifty virtual minutes at the engine's 5s cadence — long enough to cover
        // the whole retry episode (t, t+15, t+30) and to make a per-tick loop
        // unmissable in the counts below.
        let ticks = await drive(
            database, core: core, seam: seam, uuid: uuid, reads: reads,
            censusReads: censusReads, resolutions: resolutions,
            storage: InMemoryStorage(), from: liftoff, step: 5, ticks: 600
        )

        // 1. THE RAIL FIRED — no command of any kind reached the wire, over six
        //    hundred ticks, with a healthy budget and a seam accepting everything.
        #expect(
            await seam.commands.isEmpty,
            "the reserve rail vetoes BEFORE the dispatch: nothing may reach the wire"
        )

        // 2. NO THRASH. One launch, and a retry count that is the budget rather
        //    than the tick count.
        let runs = try await relayRuns(database)
        #expect(runs.count == 1, "one launch for one target, and the stalled run keeps its carrier")
        let launched = try #require(runs.first)
        #expect(
            resolutions.retried.value == Array(repeating: launched.id, count: Brain.retryBudget),
            "exactly the retry budget's worth of auto-retries, spread over the interval, then it stops"
        )
        #expect(resolutions.cancelled.value.isEmpty, "a resource shortage is not a reason to cancel a run")

        // 3. NO BUDGET BURN. Three authoritative reads and two census refreshes
        //    for fifty virtual minutes; a rail re-judging per tick shows six
        //    hundred of each. LIST equalities over the WHOLE run, not ceilings, so
        //    the ~450 escalated ticks at the tail are pinned to zero too — that
        //    tail is the proof the cost tracks the retry budget, not the clock.
        //    The reads are one carrier confirm at launch plus one hub read for the
        //    2nd and 3rd retries; the 1st fires the moment the run stalls, inside
        //    both freshness windows, so it re-judges the rows it has for free.
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

    /// The positive control. Without it, "no command reached the wire" is equally
    /// satisfied by a brain that never launched, a governor that deferred
    /// everything, or a seam that was never wired up.
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

    /// **Does not drive the rail** — it reads the MIRROR
    /// (`BrainLimits.hubStockStanding`) on the world the test above proved the rail
    /// vetoes, so the card and the rail cannot tell two stories about one world.
    /// The mirror↔rail agreement itself is pinned by
    /// `BrainCeilingTests.hubStockStandingAgreesWithTheRailItMirrors`; what is
    /// added here is that both are pointed at the same WORLD.
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

    /// `commitBlocker`'s `inFlightSources` arm, previously checked only on the
    /// SELECTION side. A second run claims `RDEG_A` after the confirm-read and
    /// before the insert, driven off the `uuid` generator — the one deterministic
    /// seam between them. The tick must DEFER wholesale rather than fall back to a
    /// print.
    ///
    /// **Scope:** this pins the guard's LOGIC, not its PLACEMENT. The racing row
    /// commits strictly before `database.write` opens, so a re-check hoisted just
    /// outside the transaction would pass too — pinning the placement would need a
    /// writer interleaving inside GRDB's serialized queue, which is what that
    /// queue exists to prevent.
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

    /// The positive control. Without it, "no second run was written" is equally
    /// satisfied by a world where the brain would never have reclaimed anything.
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

    /// Reclaim never strands live value, and the guard is the confirm-read. The
    /// brain names `RDEG_A` off a day-old row; the authoritative read says somebody
    /// got there first. The run must neither `deactivate` on the stale row nor fall
    /// back to a print the plan declined — it stalls, mesh intact. The assertion is
    /// on the WIRE, not the step: a run that acted on stale evidence shows a command.
    @Test func aStaleSourceRowNeverAuthorisesTearingARelayDown() async throws {
        let database = try GameDatabase.bootstrap()
        // Stamped a DAY before the tick, far past `reclaimFreshness`.
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

    /// Unknown is left alone: the world that ranks VEGA first, minus the assay.
    /// The brain must not treat "no value data" as "no value" — `tendMesh` meshes
    /// toward KNOWN value, and survey is a separate goal. Both halves are asserted
    /// together because either alone is worthless: a brain that ranked nothing
    /// would pass the first, one that ranked everything would pass the second.
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

    /// The confirm-read comes back nil for twenty ticks. Each defers with its own
    /// distinct reason, writes no row and dispatches no command; then the read
    /// lands and the next tick launches exactly once, the deferral never having
    /// been remembered.
    ///
    /// **Scope, because the obvious reading is too generous.** This proves a
    /// deferred tick writes and spends nothing. It does NOT prove the path is
    /// cheap: the count below is one `.high` read per tick — 12/min for as long as
    /// the API stays down, with no backoff. Bounded read cost is proven for the
    /// STALL-RETRY path only. The assertion pins that ceiling rather than
    /// endorsing it.
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

    /// An idle brain and a stuck brain must not look alike, driven end-to-end
    /// through the real stack in both worlds rather than over hand-built reports.
    /// Checked on the three things that carry the distinction: the published
    /// decision, that neither is a deferral, and the ledger — the idle world
    /// surfaces nothing, the stuck world exactly one row carrying its reason.
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

    /// The backoff, read off the timeline the retries actually wrote. Three
    /// auto-retries a tick apart would spend the whole budget inside one print's
    /// duration and escalate a shortage a delivery cycle would have cleared. The
    /// first attempt is deliberately unspaced — there is no `.resolved` entry to
    /// measure from — so only the gaps BETWEEN attempts are the backoff.
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
        // An INDEPENDENT anchor: the line above compares the gaps against the very
        // constant that produces them, so it still passes at `retryInterval == 0`.
        // `hubFreshness` is the information floor below which a retry re-reads
        // numbers the run already considers current and can only burn an attempt.
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
