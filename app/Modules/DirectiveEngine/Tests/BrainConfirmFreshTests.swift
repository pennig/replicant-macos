//
//  BrainConfirmFreshTests.swift
//  Replicould — DirectiveEngine
//
//  Task 18: the rule that makes a stale snapshot safe. Ranking runs on
//  best-effort data; every irreversible commitment is gated on a just-in-time
//  `.high` confirm-read. Staleness may cost efficiency — never safety.
//
//  The race being closed is real, not hypothetical: `Brain.evaluateOnce` reads
//  its world, then writes a directive, and the UI launchers
//  (`NewDirectiveFeature`) can insert a directive on the very vessel the brain
//  has just chosen in that window. Note that such a launch leaves the DEVICE
//  row untouched — it writes a `directives` row — which is why
//  `anOperatorLaunchInsideTheWindowIsCaughtByTheConfirm` below is the load
//  -bearing one: a gate that re-read only the device would sail straight past
//  it.
//
//  Two properties the tests pin as hard as the outcome itself:
//
//  - **Proceed or defer, never re-rank.** A deferred tick writes nothing and
//    reports why; it does not fall through to the runner-up candidate or to a
//    spare carrier, and it does not retry inside the tick.
//  - **The gate is not a poll.** The confirm fires only on a tick that has
//    something to commit, which is what keeps a 5-second loop from becoming a
//    `.high` read against the live API every 5 seconds. Proven by recording
//    the reads, not by asserting the outcome.
//
//  On `uuid`: threaded per TEST, never per tick — `UUIDGenerator.incrementing`
//  is a computed property that mints a fresh generator per access, so
//  re-entering `withDependencies` per tick would make every "wrote no row"
//  assertion incapable of failing (the second insert would collide on the
//  primary key and degrade to `.idle` regardless of the gate). Same reasoning,
//  and the same shape, as `BrainGrowTests`.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels

@testable import DirectiveEngine

private let tickTime = Date(timeIntervalSince1970: 1_000)

/// The reason a tick defers because the confirm-read came back NEGATIVE — the
/// carrier is really no longer free.
private let carrierTakenReason = "deferred — carrier V1 unavailable on confirm"

/// The reason a tick defers because the confirm-read could not be had at all.
/// Deliberately a DIFFERENT string: "we couldn't confirm" is not "it's fine",
/// and an operator reading the why-view has to be able to tell the two apart.
private let confirmFailedReason = "deferred — carrier V1 could not be confirmed"

private func decide(
    _ database: any DatabaseWriter, uuid: UUIDGenerator, refresher: DeviceRefreshClient
) async -> BrainDecision {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(tickTime)
        $0.uuid = uuid
        $0.deviceRefresher = refresher
    } operation: {
        await Brain(now: tickTime).evaluateOnce()
    }
}

private func relayRuns(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in
        try Directive.where { $0.kind.eq(DirectiveKind.relayRun) }.order { $0.id }.fetchAll(db)
    }
}

@Suite("Brain — the confirm-fresh gate")
struct BrainConfirmFreshTests {
    /// The headline: the snapshot said V1 was idle at the hub, the confirm-read
    /// says it is already flying. The tick DEFERS — no directive row, and a
    /// reason legible enough to render.
    ///
    /// Without the gate this is a Relay Run launched onto a vessel that is
    /// leaving the hub, which `RelayRun.acquire` then stalls on
    /// (`unreachableDevice`) after burning the operator's attention.
    @Test func aCarrierThatMovedSinceRankingIsDeferredNotLaunched() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let reads = LockIsolated<[ConfirmRead]>([])
        let refresher = confirmingRefresher(database, reads: reads) { device in
            var moved = device
            moved.status = "travelling"
            return moved
        }

        let decision = await decide(database, uuid: uuid, refresher: refresher)

        #expect(decision == .idle(reason: carrierTakenReason))
        #expect(try await relayRuns(database).isEmpty, "a deferred tick writes nothing")
        #expect(
            reads.value == [ConfirmRead(deviceCode: "V1", isHigh: true)],
            "one confirm-read, for the carrier about to be committed, at .high"
        )
    }

    /// **The race the task exists to close.** The operator hits "launch" in the
    /// read→write window: a Survey Run lands on V1 between the brain ranking
    /// and the brain committing.
    ///
    /// The device row is untouched by that — a UI launch writes a `directives`
    /// row and nothing else — so a confirm that re-read only the vessel would
    /// see an idle heaven vessel standing at the hub and happily launch a
    /// second directive owning the same carrier. The confirm therefore re-reads
    /// the LEDGER as well and re-applies the reservation rules to it.
    @Test func anOperatorLaunchInsideTheWindowIsCaughtByTheConfirm() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let refresher = confirmingRefresher(database) { device in
            try? await database.write { db in
                try seedDirective(db, id: "OPERATOR", kind: .surveyRun, deviceCode: "V1")
            }
            return device   // the vessel itself has not moved, and never does
        }

        let decision = await decide(database, uuid: uuid, refresher: refresher)

        #expect(decision == .idle(reason: carrierTakenReason))
        #expect(
            try await relayRuns(database).isEmpty,
            "the operator's run owns V1 now — a second directive on the same carrier is the bug"
        )
    }

    /// **The other half of that race — the interleaving that a pre-write check
    /// cannot survive.** Same operator launch, but committed AFTER the brain's
    /// confirm-read has returned.
    ///
    /// The racing insert is driven from the `uuid` generator, which the brain
    /// resolves once the confirm-read is in hand and immediately before it
    /// opens its write transaction — the one deterministic seam that sits
    /// between the two. `DatabaseWriter`'s synchronous `write` commits the row
    /// there and then, so by the time the brain's own transaction opens the
    /// collision is already on disk.
    ///
    /// A gate that re-read the ledger in a transaction of its own and then
    /// inserted in a second one passes the pre-read test above and fails this
    /// one: it would insert a second directive owning V1. Only a re-check
    /// taken INSIDE the insert's transaction catches both.
    @Test func anOperatorLaunchAfterTheConfirmReadIsStillCaught() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowableWorld(db) }
        let racing = UUIDGenerator {
            try? database.write { db in
                try seedDirective(db, id: "OPERATOR", kind: .surveyRun, deviceCode: "V1")
            }
            return UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
        }

        let decision = await decide(database, uuid: racing, refresher: confirmingRefresher(database))

        #expect(decision == .idle(reason: carrierTakenReason))
        #expect(
            try await relayRuns(database).isEmpty,
            "the operator's row landed after the confirm-read — only an in-transaction re-check sees it"
        )
    }

    /// The in-flight-target predicate is re-checked at commit time too, not
    /// only during selection. A second Relay Run aimed at VEGA lands in the
    /// window; V1 itself is still perfectly free (the other run flies V2), so
    /// nothing but that predicate can stop this tick.
    ///
    /// Latent today — no UI constructs a `.relayRun` and the brain loop is
    /// serial — and asserted anyway, because it goes live the moment a second
    /// brain-side launcher lands (prune, or a multi-launch pass), and the cost
    /// of missing it is the 370-unit, ~800 s duplicate print the selection-side
    /// filter already exists to prevent.
    @Test func aTargetTakenByAnotherRelayRunInTheWindowIsDeferred() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: ["V1", "V2"], salvage: ["VEGA": 3_200])
        }
        let racing = UUIDGenerator {
            try? database.write { db in
                try seedRelayRun(db, id: "OTHER", deviceCode: "V2", targets: ["VEGA"])
            }
            return UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!
        }

        let decision = await decide(database, uuid: racing, refresher: confirmingRefresher(database))

        #expect(decision == .idle(reason: "deferred — VEGA already in flight on confirm"))
        let runs = try await relayRuns(database)
        #expect(runs.map(\.id) == ["OTHER"], "the brain must not add a second run to the same hop")
    }

    /// **A carrier that drifted to a SIBLING LOCATION in the same system is not
    /// free.** `SOL-4` is not `SOL-3`: the vessel is idle, unreserved and still
    /// in the meshed system, and it is still wrong to launch on it — the relay
    /// materialises at the printer, so `RelayRun.acquire` would stall
    /// `unreachableDevice` on its first evaluation.
    ///
    /// This is the test that makes `Plan.grow`'s `hub` payload load-bearing.
    /// Re-testing co-location against the lossy `origin` ("SOL"), or against
    /// the carrier's own fresh location (a tautology), passes every other test
    /// in this file and fails this one.
    @Test func aCarrierThatDriftedToASiblingLocationIsDeferred() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let refresher = confirmingRefresher(database) { device in
            var drifted = device
            drifted.location = "SOL-4"   // same system, different location
            return drifted
        }

        let decision = await decide(database, uuid: uuid, refresher: refresher)

        #expect(decision == .idle(reason: carrierTakenReason))
        #expect(try await relayRuns(database).isEmpty)
    }

    /// A confirm-read that FAILS defers too, and says so in its own words. Fail
    /// -closed, the same reasoning the reserve rail uses: "we could not confirm"
    /// is not "it is fine".
    ///
    /// A `.high` refresh is suppressed by neither the TTL nor the read-budget
    /// floor (`PollCoordinator.refresh` applies both to `.low` only), so nil
    /// here means the authoritative read genuinely did not land.
    @Test func aConfirmReadThatFailsDefersWithItsOwnReason() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let reads = LockIsolated<[ConfirmRead]>([])
        let refresher = confirmingRefresher(database, reads: reads) { _ in nil }

        let decision = await decide(database, uuid: uuid, refresher: refresher)

        #expect(decision == .idle(reason: confirmFailedReason))
        #expect(try await relayRuns(database).isEmpty, "an unconfirmable carrier is never committed to")
        #expect(reads.value.count == 1, "…and the tick does not retry the read it just failed")
    }

    /// The Task 16 behaviour, intact: a confirm that comes back CLEAN launches
    /// exactly the run it was going to launch, on exactly the carrier ranking
    /// chose.
    ///
    /// Without this the gate could be "always defer" and every other test in
    /// this file would still pass.
    @Test func aConfirmedCarrierLaunchesExactlyAsBefore() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let reads = LockIsolated<[ConfirmRead]>([])
        let refresher = confirmingRefresher(database, reads: reads)

        let decision = await decide(database, uuid: uuid, refresher: refresher)

        guard case let .dispatch(goal, ranked) = decision else {
            Issue.record("expected a dispatch, got \(decision)")
            return
        }
        #expect(goal.kind == .tendMesh)
        #expect(goal.target == "VEGA")
        #expect(ranked.map(\.firstHop) == ["VEGA"])
        let launched = try await relayRuns(database)
        #expect(launched.count == 1)
        #expect(launched.first?.deviceCode == "V1")
        #expect(launched.first?.targets == ["VEGA"])
        #expect(launched.first?.status == .running)
        #expect(launched.first?.step == RelayRun().firstStep)
        #expect(
            reads.value == [ConfirmRead(deviceCode: "V1", isHigh: true)],
            "one .high confirm-read paid for one commitment"
        )
    }

    /// **The rate-limit protection, proven rather than claimed.** A tick with
    /// nothing worth reaching issues NO confirm-read — three ticks in a row,
    /// so a gate that fired once per tick would show three reads here.
    ///
    /// This is the whole reason the confirm sits behind the plan rather than in
    /// front of it: the brain ticks every 5 seconds, and an unconditional
    /// confirm would be 12 `.high` reads a minute against the live API forever,
    /// in a world where there is nothing to commit to.
    @Test func aTickWithNothingWorthLaunchingIssuesNoConfirmRead() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db, salvage: [:]) }
        let reads = LockIsolated<[ConfirmRead]>([])
        let refresher = confirmingRefresher(database, reads: reads)

        for _ in 0..<3 {
            #expect(
                await decide(database, uuid: uuid, refresher: refresher)
                    == .idle(reason: "no grow or prune work")
            )
        }

        #expect(reads.value.isEmpty, "the gate must not become a per-tick .high poll")
    }

    /// …and neither does a tick that found value but no carrier to send. There
    /// is nothing to confirm — the tick has already decided it is committing to
    /// nothing — so the read is not spent.
    @Test func aTickWithNoFreeCarrierIssuesNoConfirmRead() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db, carriers: []) }
        let reads = LockIsolated<[ConfirmRead]>([])
        let refresher = confirmingRefresher(database, reads: reads)

        #expect(
            await decide(database, uuid: uuid, refresher: refresher)
                == .idle(reason: "no free carrier at SOL-3")
        )
        #expect(reads.value.isEmpty)
    }

    /// **The confirm can only proceed or defer — it never re-ranks.** Two
    /// candidates and two carriers: ranking picks VEGA on V1, the confirm says
    /// V1 is gone, and the tick stops.
    ///
    /// Everything a re-ranking confirm would need is deliberately present —
    /// ALTAIR is unclaimed and V2 is free and idle at the hub — so a gate that
    /// "helpfully" retried with the runner-up would launch here and fail this
    /// test. Re-ranking on the confirm would make the decision depend on read
    /// timing, which is exactly the property the gate exists to remove.
    @Test func aDeferredConfirmNeverFallsThroughToAnotherCandidateOrCarrier() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db, carriers: ["V1", "V2"], salvage: ["VEGA": 3_200, "ALTAIR": 100])
        }
        let reads = LockIsolated<[ConfirmRead]>([])
        // Only V1 has moved. V2 would confirm free if it were ever asked — and
        // the point of the test is that it is not asked.
        let refresher = confirmingRefresher(database, reads: reads) { device in
            guard device.deviceCode == "V1" else { return device }
            var moved = device
            moved.status = "travelling"
            return moved
        }

        let decision = await decide(database, uuid: uuid, refresher: refresher)

        #expect(decision == .idle(reason: carrierTakenReason))
        #expect(
            try await relayRuns(database).isEmpty,
            "ALTAIR is unclaimed and V2 is free — only a gate that refuses to re-rank stops this tick"
        )
        #expect(
            reads.value == [ConfirmRead(deviceCode: "V1", isHigh: true)],
            "one confirm for the one candidate ranking chose; the spare carrier is not shopped"
        )
    }

    /// Stateless between ticks: a deferral is not remembered. The same brain,
    /// the same world, and a carrier that has come back to rest — the next tick
    /// re-reads, re-decides from scratch, and launches.
    ///
    /// The complement of the deferral tests: it proves a defer costs a tick of
    /// patience rather than parking the brain, and that nothing about the first
    /// tick's answer is carried into the second.
    @Test func aDeferralIsNotRememberedAndTheNextTickReDecides() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let reads = LockIsolated<[ConfirmRead]>([])
        let flying = LockIsolated(true)
        let refresher = confirmingRefresher(database, reads: reads) { device in
            guard flying.value else { return device }
            var moved = device
            moved.status = "travelling"
            return moved
        }

        #expect(await decide(database, uuid: uuid, refresher: refresher) == .idle(reason: carrierTakenReason))
        #expect(try await relayRuns(database).isEmpty)

        flying.setValue(false)
        guard case .dispatch = await decide(database, uuid: uuid, refresher: refresher) else {
            Issue.record("a deferred tick must not park the brain — the next tick re-decides")
            return
        }
        #expect(try await relayRuns(database).count == 1)
        #expect(reads.value.count == 2, "one confirm per committing tick, neither cached nor skipped")
    }
}
