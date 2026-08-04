//
//  BrainStallResponseTests.swift
//  Replicould — DirectiveEngine
//
//  Task 17: the brain answers its OWN halted missions as an automated
//  operator — and only in the two ways it is allowed to.
//
//  Every suite here is built around one property: the brain's operator powers
//  are exactly `{retry, cancel}`, and `skipTarget`/`pause`/`resume` are
//  operator-only, permanently. That is enforced structurally rather than
//  asserted — every resolution client in this file stubs those three with
//  `unimplemented(...)`, so a brain that ever drove one fails the test that
//  touched it, loudly, wherever it happened. Deleting the guard in `Brain`
//  cannot make these tests pass.
//
//  The worlds here deliberately have NO mesh, so `Brain.plan` idles and the
//  decision each tick reports is the stall layer's alone. `BrainGrowTests`
//  owns the launch path; nothing here re-proves it.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing

@testable import DirectiveEngine

/// `t(0)` is the epoch these tests measure from. A non-zero base keeps the
/// spacing arithmetic (`now - lastAttempt`) away from the `timeIntervalSince1970
/// == 0` default every fixture row carries, so a comparison accidentally made
/// against a fixture stamp shows up as a wrong answer rather than as a
/// coincidentally-correct one.
private func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

/// A resolution client that records what the brain drove — and makes the three
/// operator-only verbs impossible to drive quietly.
///
/// `retry` records AND performs the real `liveValue` transition. That is the
/// point: the brain's budget is derived from the `.resolved` entries `retry`
/// writes, so a stub that only recorded would leave the budget reading zero
/// forever and every "then escalates" assertion would pass vacuously. With the
/// live verb in the loop the timeline under test is the one production builds.
///
/// `cancel` records without acting — this task never drives it, and the
/// assertion that matters is that it stayed empty.
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
            resume: unimplemented("DirectiveResolutionClient.resume")
        )
    }
}

/// One brain tick at `now`. `uuid` is threaded from the caller and never
/// defaulted, for the reason `BrainGrowTests` records: `.incrementing` is a
/// COMPUTED property, so a fresh one per tick would mint the same id every
/// time — and `directiveLogEntries.id` is a `TEXT PRIMARY KEY`, so the second
/// auto-retry's `.resolved` entry would collide, the whole write would roll
/// back into `apply`'s catch, and the row would silently never leave
/// `.needsAttention`. Every budget assertion in this file would then be
/// incapable of failing.
private func decide(
    _ database: any DatabaseWriter,
    at now: Date,
    uuid: UUIDGenerator,
    resolutions: Resolutions
) async -> BrainDecision {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(now)
        $0.uuid = uuid
        $0.directiveResolution = resolutions.client
    } operation: {
        await Brain(now: now).evaluateOnce()
    }
}

private func row(_ database: any DatabaseWriter, _ id: String) async throws -> Directive? {
    try await database.read { db in try Directive.where { $0.id.eq(id) }.fetchOne(db) }
}

/// Re-stall a directive the brain just retried, the way the executor would on
/// its next pass. Returns whether it fired, so a test can assert the retry
/// actually returned the row to `.running` rather than assuming it.
@discardableResult
private func reStallIfRetried(
    _ database: any DatabaseWriter,
    _ id: String,
    reason: DirectiveAttentionReason,
    entryID: String,
    at: Date
) async throws -> Bool {
    guard try await row(database, id)?.status == .running else { return false }
    try await database.write { db in
        try stallDirective(db, id: id, reason: reason, entryID: entryID, at: at)
    }
    return true
}

/// A `.needsAttention` Relay Run as a VALUE, for the passes that are pure
/// functions over (directive, timeline) and have no business touching a
/// database to be tested.
private func stalledRelayRun(
    id: String = "D1",
    step: String = "acquire",
    reason: DirectiveAttentionReason = .printStockShort
) -> Directive {
    Directive(
        id: id, kind: .relayRun, status: .needsAttention, deviceCode: "V1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["VEGA"], targetIndex: 0, step: step, stepStartedAt: t(0),
        returnToOrigin: false, originDesignation: "SOL", attentionReason: reason,
        createdAt: t(0), updatedAt: t(0)
    )
}

/// One timeline entry as a value, oldest-first ordering supplied by the caller.
private func logEntry(
    _ kind: DirectiveLogKind, step: String?, at seconds: Double, id: String = UUID().uuidString
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: kind, summary: "",
        step: step, operationID: nil, eventID: nil, occurredAt: t(seconds)
    )
}

@Suite("Brain — stall response")
struct BrainStallResponseTests {
    /// **The headline, driven as a real cycle.** A Relay Run halted with a
    /// `.retry`-disposition reason is auto-retried — and re-stalls, and is
    /// retried again — until the timeline-derived budget is spent, at which
    /// point the brain stops and leaves it escalated.
    ///
    /// The assertion is on the whole TRANSITION, not the final state: ticks 1–3
    /// each drive exactly one `retry` and report a calm `.idle`, and ticks 4–5
    /// drive nothing and report `.stall`. A brain that never retried, one that
    /// retried forever, and one that escalated immediately each fail a
    /// different element of these two sequences.
    ///
    /// Nothing here is simulated except the executor's own re-stall, which is
    /// written through `stallDirective` — byte-identical to
    /// `DirectiveExecutor.stall`'s row change and `.stalled` entry. The
    /// `.resolved` entries the budget is actually counted from are written by
    /// the LIVE resolution verb.
    @Test func aRetryDispositionStallIsAutoRetriedThenLeftEscalated() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            try seedRelayRun(db, id: "D1")
            try stallDirective(db, id: "D1", reason: .printStockShort, entryID: "S0", at: t(0))
        }
        #expect(
            DirectiveAttentionReason.printStockShort.brainDisposition == .retry,
            "the fixture is only meaningful while this reason is classified .retry"
        )

        var decisions: [BrainDecision] = []
        var reStalls = 0
        // Ticks are two minutes apart so the per-directive spacing floor is
        // never what stops a retry here — this test is about the BUDGET.
        // `aRecentlyRetriedStallWaitsInsteadOfRetryingAgain` owns spacing.
        for attempt in 0..<5 {
            let now = t(Double(attempt) * 1_200)
            decisions.append(await decide(database, at: now, uuid: uuid, resolutions: resolutions))
            if try await reStallIfRetried(
                database, "D1", reason: .printStockShort,
                entryID: "S\(attempt + 1)", at: now.addingTimeInterval(1)
            ) { reStalls += 1 }
        }

        #expect(resolutions.retried.value == ["D1", "D1", "D1"], "exactly the budget's worth, then it stops")
        #expect(reStalls == 3, "each of those retries really returned the row to .running")
        #expect(
            decisions == [
                .idle(reason: "no mesh yet"), .idle(reason: "no mesh yet"), .idle(reason: "no mesh yet"),
                .stall(.printStockShort), .stall(.printStockShort),
            ],
            "a handled stall reports calm; an exhausted one reports escalated, and keeps saying so"
        )
        #expect(resolutions.cancelled.value.isEmpty, "the brain does not cancel a stalled run in this task")

        let final = try #require(try await row(database, "D1"))
        #expect(final.status == .needsAttention)
        #expect(final.attentionReason == .printStockShort, "escalation leaves the reason intact for the operator")
        #expect(final.step == RelayRun().firstStep, "the brain never hand-edits a running directive's step")
        #expect(final.targets == ["VEGA"], "…nor its targets")
    }

    /// An `.escalate`-disposition stall is never auto-resolved — the brain
    /// lacks the power the reason names (here: stowing a relay), so it leaves
    /// the run surfaced and untouched, however many ticks pass.
    ///
    /// The row-for-row comparison is what makes this able to fail on more than
    /// the retry count: a brain that touched the row at all — restamping
    /// `updatedAt`, clearing the reason — fails it even if it drove no verb.
    @Test func anEscalateDispositionStallIsNeverAutoResolved() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            try seedRelayRun(db, id: "D1")
            try stallDirective(db, id: "D1", reason: .noRelayCoLocated, entryID: "S0", at: t(0))
        }
        #expect(DirectiveAttentionReason.noRelayCoLocated.brainDisposition == .escalate)
        let before = try #require(try await row(database, "D1"))

        for tick in 0..<4 {
            #expect(
                await decide(database, at: t(Double(tick) * 1_200), uuid: uuid, resolutions: resolutions)
                    == .stall(.noRelayCoLocated)
            )
        }

        #expect(resolutions.retried.value.isEmpty, "an escalate reason is never retried, not even once")
        #expect(resolutions.cancelled.value.isEmpty)
        #expect(try await row(database, "D1") == before, "…and the row is left exactly as the operator will find it")
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.map(\.id) == ["S0"], "no timeline entry beyond the stall the executor wrote")
    }

    /// **The loud property: the brain never drives an operator-only verb.**
    ///
    /// `skipTarget`, `pause` and `resume` are `unimplemented` here — any call
    /// records a test failure at the moment it happens, so this cannot be
    /// satisfied by a brain that merely avoids them on the paths the other
    /// tests happen to walk. Both dispositions are on the board at once, and
    /// the retry arm is driven past its budget so the exhaustion branch is
    /// walked too: the whole stall layer runs, several times over, with those
    /// three verbs armed.
    ///
    /// A brain that "resolved" a stall it could not fix by skipping the target
    /// — the single most tempting shortcut in this design, and one the design
    /// notes record as REJECTED — fails here rather than shipping.
    @Test func brainNeverDrivesOperatorOnlyVerbs() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            try seedRelayRun(db, id: "D1", deviceCode: "V1")
            try stallDirective(db, id: "D1", reason: .relayActivationFailed, entryID: "A0", at: t(0))
            try seedRelayRun(db, id: "D2", deviceCode: "V2")
            try stallDirective(db, id: "D2", reason: .awaitingRelayRestock, entryID: "B0", at: t(0))
        }
        #expect(DirectiveAttentionReason.relayActivationFailed.brainDisposition == .retry)
        #expect(DirectiveAttentionReason.awaitingRelayRestock.brainDisposition == .escalate)

        // Well past the budget, so the retry arm is driven through spend AND
        // exhaustion while the three forbidden verbs are armed.
        for tick in 0..<8 {
            let now = t(Double(tick) * 1_200)
            _ = await decide(database, at: now, uuid: uuid, resolutions: resolutions)
            try await reStallIfRetried(
                database, "D1", reason: .relayActivationFailed,
                entryID: "A\(tick + 1)", at: now.addingTimeInterval(1)
            )
        }

        // Reaching here at all is the assertion — `unimplemented` fails the
        // test from inside the call. These record what DID happen, so a
        // regression reads as a diff rather than as a silent pass.
        #expect(resolutions.retried.value == ["D1", "D1", "D1"])
        #expect(resolutions.cancelled.value.isEmpty)
        #expect(try await row(database, "D2")?.attentionReason == .awaitingRelayRestock)
        #expect(try await row(database, "D2")?.targetIndex == 0, "skipTarget would have advanced this")
    }

    /// A stalled directive that is not a Relay Run is left **entirely** alone —
    /// not retried, not reported. The brain manages its own missions; a Survey
    /// Run the operator launched is the operator's, and its
    /// `.retry`-disposition reason is not an invitation.
    ///
    /// Every verb is `unimplemented` (`testValue`), so any touch at all fails
    /// loudly rather than being caught only by the recorder being empty.
    @Test func aStalledDirectiveOfAnotherKindIsLeftEntirelyAlone() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedDirective(db, id: "S1", kind: .surveyRun, status: .running, deviceCode: "V1")
            try stallDirective(db, id: "S1", reason: .commandRejected, entryID: "S0", at: t(0))
        }
        #expect(DirectiveAttentionReason.commandRejected.brainDisposition == .retry)
        let before = try #require(try await row(database, "S1"))

        let decision = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t(600))
            $0.uuid = .incrementing
            $0.directiveResolution = .testValue
        } operation: {
            await Brain(now: t(600)).evaluateOnce()
        }

        #expect(decision == .idle(reason: "no mesh yet"), "another kind's stall is not even reported as the brain's")
        #expect(try await row(database, "S1") == before)
    }

    /// **Budget accounting is per-directive, never global.** D1 has already
    /// spent its whole budget; D2 has spent none. One tick retries D2 and
    /// leaves D1 escalated.
    ///
    /// This is the pile-up case the Relay Run design produces on purpose: N
    /// free carriers in a resource-short world launch N runs that each stall
    /// the same way. A budget counted across the ledger would either refuse D2
    /// (because D1 exhausted the shared count) or hand D1 more attempts
    /// (because D2's zero dragged the count down); the reasons are chosen
    /// distinct so the reported escalation names D1 unambiguously.
    @Test func theRetryBudgetIsAccountedPerDirectiveNotGlobally() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            try seedRelayRun(db, id: "D1", deviceCode: "V1")
            try stallDirective(db, id: "D1", reason: .relayActivationFailed, entryID: "A0", at: t(0))
            // Three spent attempts on D1's current step: each a `.resolved`
            // entry followed by the executor's re-stall, exactly the shape the
            // live cycle leaves behind.
            for attempt in 1...3 {
                try seedLogEntry(
                    db, id: "R\(attempt)", directiveID: "D1", kind: .resolved,
                    summary: "Retried \(RelayRun().firstStep)", step: RelayRun().firstStep,
                    at: t(Double(attempt) * 10)
                )
                try seedLogEntry(
                    db, id: "A\(attempt)", directiveID: "D1", kind: .stalled,
                    summary: "relayActivationFailed", step: RelayRun().firstStep,
                    at: t(Double(attempt) * 10 + 1)
                )
            }
            try seedRelayRun(db, id: "D2", deviceCode: "V2")
            try stallDirective(db, id: "D2", reason: .printStockShort, entryID: "B0", at: t(0))
        }

        let decision = await decide(database, at: t(600), uuid: uuid, resolutions: resolutions)

        #expect(resolutions.retried.value == ["D2"], "D1's spent budget must not spend D2's")
        #expect(decision == .stall(.relayActivationFailed), "…and D1 is still the one that needs a human")
        #expect(try await row(database, "D2")?.status == .running, "D2's retry really landed")
        #expect(try await row(database, "D1")?.status == .needsAttention)
    }

    /// **At most one auto-retry per tick**, the same discipline `Brain.plan`
    /// already applies to launches: however many stalls pile up, a tick spends
    /// one action and re-reads the world five seconds later.
    ///
    /// Three identical fresh stalls, so nothing but the one-per-tick rule can
    /// explain a single retry — all three are eligible on the first tick.
    ///
    /// **Each retried run is re-stalled before the next tick**, which is what
    /// makes the second half test its own message: without that, a retried run
    /// goes `.running` and drops out of candidacy on its own, so successive
    /// ticks would pick the next id whatever the ordering rule was. With the
    /// pile kept PERSISTENT — all three rows halted at the start of every tick
    /// — D2-before-D3 is a real ordering assertion (both have never been
    /// attempted, so the directive-id tie-break decides), and D1 not being
    /// picked again is the spacing floor doing its job.
    @Test func atMostOneAutoRetryLandsPerTick() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            for (index, id) in ["D1", "D2", "D3"].enumerated() {
                try seedRelayRun(db, id: id, deviceCode: "V\(index + 1)")
                try stallDirective(db, id: id, reason: .printStockShort, entryID: "S-\(id)", at: t(0))
            }
        }

        _ = await decide(database, at: t(10), uuid: uuid, resolutions: resolutions)
        #expect(resolutions.retried.value == ["D1"], "three eligible stalls, one action")
        #expect(
            try await reStallIfRetried(database, "D1", reason: .printStockShort, entryID: "S-D1-b", at: t(11)),
            "D1 must really have gone .running, or the pile below isn't persistent"
        )

        _ = await decide(database, at: t(20), uuid: uuid, resolutions: resolutions)
        #expect(
            resolutions.retried.value == ["D1", "D2"],
            "D1 is inside its spacing floor and D2 has never been attempted, so D2 is next"
        )
        try await reStallIfRetried(database, "D2", reason: .printStockShort, entryID: "S-D2-b", at: t(21))

        _ = await decide(database, at: t(30), uuid: uuid, resolutions: resolutions)
        #expect(
            resolutions.retried.value == ["D1", "D2", "D3"],
            "…and the pile is worked through one per tick, never two"
        )
    }

    /// **Starvation guard.** When several stalls are eligible at once the
    /// tick's one retry goes to whichever has WAITED LONGEST, not to the lowest
    /// id — here D2, despite D1 sorting first.
    ///
    /// Ordering by id alone starves the tail: with a 5-second tick and a
    /// `retryInterval`-long floor, a low-id directive that has just become
    /// eligible again always outranks a high-id one, which is then never
    /// retried, never spends budget, and so never reaches `.escalated` either —
    /// held silently and reported to nobody. Both directives below are past the
    /// floor, so eligibility cannot explain the choice; only the wait can.
    @Test func theLongestWaitingEligibleStallIsRetriedFirst() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            // D1 sorts first by id but was attended to recently.
            try seedRelayRun(db, id: "D1", deviceCode: "V1")
            try stallDirective(db, id: "D1", reason: .printStockShort, entryID: "A0", at: t(0))
            try seedLogEntry(
                db, id: "R-D1", directiveID: "D1", kind: .resolved,
                summary: "Retried", step: RelayRun().firstStep, at: t(3_000)
            )
            try stallDirective(db, id: "D1", reason: .printStockShort, entryID: "A1", at: t(3_001))

            // D2 sorts last but has been waiting since long before that.
            try seedRelayRun(db, id: "D2", deviceCode: "V2")
            try stallDirective(db, id: "D2", reason: .printStockShort, entryID: "B0", at: t(0))
            try seedLogEntry(
                db, id: "R-D2", directiveID: "D2", kind: .resolved,
                summary: "Retried", step: RelayRun().firstStep, at: t(10)
            )
            try stallDirective(db, id: "D2", reason: .printStockShort, entryID: "B1", at: t(11))
        }

        // Both are past the floor at this instant (D1 by ~17 min, D2 by ~66).
        _ = await decide(database, at: t(4_000), uuid: uuid, resolutions: resolutions)

        #expect(resolutions.retried.value == ["D2"], "the longest wait wins, not the lowest id")
        #expect(try await row(database, "D1")?.status == .needsAttention, "…and D1 keeps its place in the queue")
    }

    /// A stall retried moments ago is left alone this tick — and is NOT
    /// reported as escalated, because the brain is still handling it.
    ///
    /// Without the spacing floor a directive with budget left is retried on
    /// every 5-second tick, which for a pile-up of N carriers is N API-driving
    /// actions every five seconds against a condition that has had no time to
    /// change. The two ticks below differ ONLY in their clock, so the spacing
    /// floor is the only thing that can explain the difference — and the
    /// "too soon" one sits ten minutes out, so the floor's calibration is
    /// pinned rather than just its existence.
    @Test func aRecentlyRetriedStallWaitsInsteadOfRetryingAgain() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            try seedRelayRun(db, id: "D1")
            try stallDirective(db, id: "D1", reason: .printStockShort, entryID: "S0", at: t(0))
            try seedLogEntry(
                db, id: "R1", directiveID: "D1", kind: .resolved,
                summary: "Retried \(RelayRun().firstStep)", step: RelayRun().firstStep, at: t(1)
            )
            try stallDirective(db, id: "D1", reason: .printStockShort, entryID: "S1", at: t(2))
        }

        // TEN MINUTES after the last attempt, and still too soon — the gap is
        // chosen inside the domain's own range on purpose. A floor of seconds
        // (or of one minute, which is what this shipped as before review)
        // would retry here, so this assertion pins the CALIBRATION and not
        // merely the existence of a floor.
        let tooSoon = await decide(database, at: t(600), uuid: uuid, resolutions: resolutions)
        #expect(resolutions.retried.value.isEmpty, "ten minutes after the last attempt is not a fresh attempt")
        #expect(
            tooSoon == .idle(reason: "no mesh yet"),
            "…and a stall the brain is still working is not escalated to the operator"
        )

        let later = await decide(database, at: t(1_000), uuid: uuid, resolutions: resolutions)
        #expect(resolutions.retried.value == ["D1"], "once the floor has passed, the next attempt goes out")
        #expect(later == .idle(reason: "no mesh yet"))
    }

    /// **The floor must outlast the read it depends on.** `RelayRun.acquire`
    /// believes the hub's row — and, through `footprintCensusIsStale`, the
    /// resource census the reserve rail reads — for `RelayRun.hubFreshness`
    /// before it refreshes either. A retry sooner than that re-reads numbers
    /// the run itself considers current, so it is *structurally incapable* of
    /// producing a different answer: it can only burn an attempt and bring the
    /// escalation forward.
    ///
    /// This is the invariant, not the literal — it holds for any floor at or
    /// beyond the staleness horizon, and it is what makes the three-attempt
    /// budget spendable rather than decorative. It is asserted as a relation
    /// between two constants rather than as `== 900` on purpose: pinning the
    /// number would only restate the source, where this restates the *reason*
    /// and fails if either side moves out from under the other.
    @Test func theRetryFloorOutlastsTheHubReadItDependsOn() {
        #expect(
            Brain.retryInterval >= RelayRun.hubFreshness,
            """
            a floor shorter than RelayRun.hubFreshness (\(RelayRun.hubFreshness)s) retries against a \
            snapshot the run has not re-read, so the attempt cannot change the answer
            """
        )
    }
}

@Suite("Brain — the retry episode")
struct BrainRetryEpisodeTests {
    /// A stall nobody has answered yet has spent nothing — the state every
    /// freshly-halted run is in, and the one the whole budget counts up from.
    @Test func aStallNobodyHasAnsweredHasSpentNothing() {
        let episode = Brain.retryEpisode(
            stalledRelayRun(), log: [logEntry(.stalled, step: "acquire", at: 0)]
        )
        #expect(episode == Brain.RetryEpisode(attempts: 0, lastAttemptAt: nil))
    }

    /// The live cycle's shape: resolve, re-stall, resolve, re-stall. Two
    /// attempts spent, and `lastAttemptAt` is the NEWER resolution — the one
    /// the spacing floor has to measure from. Asserting the timestamp is what
    /// would catch a walk that read the oldest entry instead, which no count
    /// assertion can see.
    @Test func countsEveryResolutionSinceTheRunLastMovedStep() {
        let episode = Brain.retryEpisode(
            stalledRelayRun(),
            log: [
                logEntry(.stalled, step: "acquire", at: 0),
                logEntry(.resolved, step: "acquire", at: 10),
                logEntry(.stalled, step: "acquire", at: 11),
                logEntry(.resolved, step: "acquire", at: 20),
                logEntry(.stalled, step: "acquire", at: 21),
            ]
        )
        #expect(episode == Brain.RetryEpisode(attempts: 2, lastAttemptAt: t(20)))
    }

    /// **The episode boundary.** Two resolutions were spent on an EARLIER
    /// visit to a different step; the run then moved on, came back, and stalled
    /// again. That is genuine progress, so the budget starts over — without
    /// this, a long mission would arrive at its last step with its retries
    /// already spent on something it recovered from an hour ago.
    ///
    /// The `travelling` entry sits between the two resolutions and the tail, so
    /// a walk that ignored `step` entirely would report 3 rather than 1.
    @Test func anEntryFromAnotherStepEndsTheEpisode() {
        let episode = Brain.retryEpisode(
            stalledRelayRun(step: "confirming"),
            log: [
                logEntry(.resolved, step: "acquire", at: 0),
                logEntry(.resolved, step: "acquire", at: 5),
                logEntry(.stepStarted, step: "travelling", at: 10),
                logEntry(.stepStarted, step: "confirming", at: 20),
                logEntry(.resolved, step: "confirming", at: 30),
                logEntry(.stalled, step: "confirming", at: 31),
            ]
        )
        #expect(episode == Brain.RetryEpisode(attempts: 1, lastAttemptAt: t(30)))
    }

    /// A step that re-issues its command and stalls again on the SAME step has
    /// looped, not progressed — so the dispatch is transparent and the budget
    /// keeps counting. Treating it as progress would reset the budget on
    /// exactly the loop the budget exists to bound, and each turn of that loop
    /// costs a live command.
    @Test func aSameStepDispatchIsNotProgress() {
        let episode = Brain.retryEpisode(
            stalledRelayRun(),
            log: [
                logEntry(.stalled, step: "acquire", at: 0),
                logEntry(.resolved, step: "acquire", at: 10),
                logEntry(.commandDispatched, step: "acquire", at: 11),
                logEntry(.stalled, step: "acquire", at: 12),
                logEntry(.resolved, step: "acquire", at: 20),
                logEntry(.commandDispatched, step: "acquire", at: 21),
                logEntry(.stalled, step: "acquire", at: 22),
            ]
        )
        #expect(episode == Brain.RetryEpisode(attempts: 2, lastAttemptAt: t(20)))
    }

    /// An `.opCompleted` entry is audit-only and deliberately BACK-DATED to
    /// when the op closed, so it is not evidence of anything happening now —
    /// and an entry with no step at all cannot say the run moved. Neither may
    /// end the episode. Here both sit inside a spent episode; a walk that
    /// stopped at either would report 0 attempts and hand the brain a fresh
    /// budget for free, every tick, forever.
    @Test func auditEntriesAndSteplessEntriesAreTransparent() {
        let episode = Brain.retryEpisode(
            stalledRelayRun(),
            log: [
                logEntry(.stalled, step: "acquire", at: 0),
                logEntry(.resolved, step: "acquire", at: 10),
                logEntry(.opCompleted, step: "acquire", at: 11),
                logEntry(.directiveCompleted, step: nil, at: 12),
                logEntry(.resolved, step: "acquire", at: 20),
                logEntry(.stalled, step: "acquire", at: 21),
            ]
        )
        #expect(episode == Brain.RetryEpisode(attempts: 2, lastAttemptAt: t(20)))
    }

    /// **The one that matters: an `.opCompleted` naming a FOREIGN step must
    /// not refund the budget.**
    ///
    /// `DirectiveExecutor.recordCompletedOps` stamps the entry with the step
    /// the command was ISSUED from and back-dates `occurredAt` to
    /// `min(max(op.lastConfirmedAt, dispatch.occurredAt), now)` —
    /// `lastConfirmedAt` advances on any later confirm-read of an
    /// already-terminal op, so an audit entry naming `travelling` can
    /// legitimately sort AFTER the move to `confirming`. Here it sits between
    /// two spent resolutions on the current step: if it ended the walk, this
    /// directive would read as having spent 1 instead of 2 and would be handed
    /// an extra retry — every tick, for free, in the unsafe direction.
    ///
    /// The sibling test above only ever placed `.opCompleted` at the CURRENT
    /// step, where the boundary never applies, so it read as coverage of a
    /// claim it did not test. This is that claim.
    @Test func anOpCompletedAtAForeignStepDoesNotRefundTheBudget() {
        let episode = Brain.retryEpisode(
            stalledRelayRun(step: "confirming"),
            log: [
                logEntry(.stepStarted, step: "confirming", at: 0),
                logEntry(.resolved, step: "confirming", at: 10),
                logEntry(.stalled, step: "confirming", at: 11),
                // Back-dated audit for a travel op issued two steps ago, landing
                // here because a later confirm-read moved its `lastConfirmedAt`.
                logEntry(.opCompleted, step: "travelling", at: 15),
                logEntry(.resolved, step: "confirming", at: 20),
                logEntry(.stalled, step: "confirming", at: 21),
            ]
        )
        #expect(episode == Brain.RetryEpisode(attempts: 2, lastAttemptAt: t(20)))
    }

    /// An operator's own resolution counts against the budget too. It is a
    /// `.resolved` entry like any other, and the direction of that choice is
    /// the safe one: a person who has just retried this step by hand and
    /// watched it re-stall does not need the brain piling automated retries on
    /// top of the same loop.
    ///
    /// A `Skipped` summary rather than `Retried` is the case that matters — an
    /// implementation that string-matched the display summary would count 0
    /// here and hand out a full budget.
    @Test func anOperatorsOwnResolutionCountsAgainstTheBudget() {
        var skipped = logEntry(.resolved, step: "acquire", at: 10)
        skipped.summary = "Skipped VEGA"
        let episode = Brain.retryEpisode(
            stalledRelayRun(),
            log: [logEntry(.stalled, step: "acquire", at: 0), skipped, logEntry(.stalled, step: "acquire", at: 11)]
        )
        #expect(episode == Brain.RetryEpisode(attempts: 1, lastAttemptAt: t(10)))
    }
}

@Suite("Brain — stall disposition coverage")
struct BrainStallDispositionTests {
    /// **Every** `.retry`-disposition reason really is auto-retried — the
    /// closed set, not the two the end-to-end tests happen to use. A reason
    /// added later and classified `.retry` is covered the moment it exists.
    @Test func everyRetryDispositionReasonIsAutoRetriedOnAFreshTimeline() {
        let retryable = DirectiveAttentionReason.allCases.filter { $0.brainDisposition == .retry }
        #expect(!retryable.isEmpty, "a vacuous loop below would otherwise prove nothing")
        for reason in retryable {
            #expect(
                Brain.stallResponse(for: stalledRelayRun(reason: reason), log: [], now: t(0))
                    == .retry(directiveID: "D1", reason: reason, attempt: 1, lastAttemptAt: nil),
                "\(reason) is classified .retry and must be auto-retried"
            )
        }
    }

    /// **The safety closure: nothing that is not a `.retry` disposition is
    /// ever auto-retried.** Written as a sweep over `allCases` rather than as
    /// a list, so it is the property that is asserted rather than today's
    /// membership — including for `.decisionRequest`, which no reason carries
    /// yet and which therefore cannot be reached any other way. The day a
    /// reason is classified `.decisionRequest`, this loop already demands it be
    /// surfaced untouched, which is the answer the design requires: a decision
    /// request IS the human-in-the-loop seam, and a brain that answered it
    /// would be making the one call it was explicitly denied.
    @Test func nothingButARetryDispositionIsEverAutoResolved() {
        for reason in DirectiveAttentionReason.allCases where reason.brainDisposition != .retry {
            #expect(
                Brain.stallResponse(for: stalledRelayRun(reason: reason), log: [], now: t(0))
                    == .escalated(directiveID: "D1", reason: reason),
                "\(reason) is \(reason.brainDisposition) — it must be surfaced, never auto-resolved"
            )
        }
    }

    /// Records that `.decisionRequest` is currently unreachable, so the sweep
    /// above is understood as a guard for the future rather than as live
    /// coverage. If this ever fails, the reason is not that something broke —
    /// it is that the branch has gone live and the report above needs
    /// revisiting.
    @Test func noAttentionReasonAsksForAnOperatorDecisionYet() {
        let requests = DirectiveAttentionReason.allCases.filter { $0.brainDisposition == .decisionRequest }
        #expect(
            requests.isEmpty,
            "\(requests) now map to .decisionRequest — the brain surfaces them untouched; confirm that is still right"
        )
    }

    /// A directive that is not halted at all draws no response, whatever its
    /// kind — the guard that stops the stall layer from reaching into a
    /// perfectly healthy running mission.
    @Test func aRunningRelayRunDrawsNoResponse() {
        var running = stalledRelayRun()
        running.status = .running
        running.attentionReason = nil
        #expect(Brain.stallResponse(for: running, log: [], now: t(0)) == nil)
        #expect(Brain.brainManagedStall(running) == nil)
    }

    /// …and neither does another kind's stall, at the pure level as well as
    /// end-to-end. `.paused` is checked too: a run the operator deliberately
    /// held is not the brain's to hand back, and `resume` is not its verb.
    @Test func onlyAHaltedRelayRunIsTheBrainsToAnswer() {
        var surveyRun = stalledRelayRun()
        surveyRun.kind = .surveyRun
        #expect(Brain.stallResponse(for: surveyRun, log: [], now: t(0)) == nil)

        var paused = stalledRelayRun()
        paused.status = .paused
        #expect(Brain.stallResponse(for: paused, log: [], now: t(0)) == nil)
    }
}
