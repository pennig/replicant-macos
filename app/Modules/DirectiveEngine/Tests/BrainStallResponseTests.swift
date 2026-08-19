//
//  BrainStallResponseTests.swift
//  Replicould — DirectiveEngine
//
//  The brain answering its OWN halted missions, and only in the two ways it may.
//  The powers are exactly `{retry, cancel}`, enforced structurally rather than
//  asserted: every resolution client here stubs the other three with
//  `unimplemented(...)`, so deleting the guard in `Brain` cannot make these pass.
//  The worlds have NO mesh, so `plan` idles and each tick's decision is the stall
//  layer's alone.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing

@testable import DirectiveEngine

/// A NON-ZERO base, so the spacing arithmetic stays away from the
/// `timeIntervalSince1970 == 0` default every fixture row carries — a comparison
/// accidentally made against a fixture stamp then shows up as a wrong answer
/// rather than a coincidentally-correct one.
private func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

/// Records what the brain drove. `retry` also performs the REAL transition: the
/// budget is derived from the `.resolved` entries it writes, so a recording-only
/// stub leaves the budget at zero and every "then escalates" assertion passes
/// vacuously. `cancel` records without acting — the assertion is that it stays empty.
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

/// One brain tick at `now`. `uuid` is threaded from the caller and never
/// defaulted: `.incrementing` is a COMPUTED property, so a fresh one per tick
/// mints the same id, the second `.resolved` entry collides on its primary key,
/// the write rolls back, and every budget assertion here becomes unable to fail.
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
    /// A `.retry`-disposition stall is auto-retried, re-stalls, is retried again,
    /// and is left escalated once the budget is spent. The assertion is on the whole
    /// TRANSITION rather than the final state — a brain that never retried, one
    /// that retried forever, and one that escalated immediately each fail a
    /// different element of the two sequences. Only the executor's re-stall is
    /// simulated; the `.resolved` entries the budget counts come from the live verb.
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
        // Ticks are spaced so the per-directive floor never stops a retry here —
        // this test is about the BUDGET.
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

    /// The brain never drives an operator-only verb. Both dispositions are on the
    /// board at once and the retry arm is driven past its budget, so the whole
    /// stall layer runs several times over with those three verbs armed. A brain
    /// that "resolved" an unfixable stall by skipping the target — the most
    /// tempting shortcut here, and one the design rejects — fails rather than ships.
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

        // Reaching here at all is the assertion — `unimplemented` fails from inside
        // the call. These record what DID happen, so a regression reads as a diff.
        #expect(resolutions.retried.value == ["D1", "D1", "D1"])
        #expect(resolutions.cancelled.value.isEmpty)
        #expect(try await row(database, "D2")?.attentionReason == .awaitingRelayRestock)
        #expect(try await row(database, "D2")?.targetIndex == 0, "skipTarget would have advanced this")
    }

    /// A stalled directive of another kind is left ENTIRELY alone — not retried,
    /// not reported. Every verb is `unimplemented` here, so any touch fails loudly
    /// rather than being caught only by the recorder being empty.
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

    /// **Budget accounting is per-directive, never global.** The pile-up case the
    /// design produces on purpose: N free carriers in a resource-short world stall
    /// N runs the same way. A ledger-wide budget would either refuse D2 or hand D1
    /// more attempts; the reasons are distinct so the escalation names D1.
    @Test func theRetryBudgetIsAccountedPerDirectiveNotGlobally() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        let resolutions = Resolutions()
        try await database.write { db in
            try seedRelayRun(db, id: "D1", deviceCode: "V1")
            try stallDirective(db, id: "D1", reason: .relayActivationFailed, entryID: "A0", at: t(0))
            // Three spent attempts on D1's current step, in the shape the live
            // cycle leaves behind: a `.resolved` entry then the executor's re-stall.
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

    /// **At most one auto-retry per tick.** Three identical fresh stalls, all
    /// eligible on the first tick, so nothing but the one-per-tick rule explains a
    /// single retry. **Each retried run is re-stalled before the next tick**, which
    /// is what makes the second half test its own message: otherwise a retried run
    /// drops out of candidacy by itself and successive ticks would pick the next id
    /// whatever the ordering rule was.
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

    /// **Starvation guard.** The tick's one retry goes to whichever has WAITED
    /// LONGEST — here D2, despite D1 sorting first. Ordering by id alone starves
    /// the tail: a low-id directive that just became eligible always outranks a
    /// high-id one, which is then never retried, never spends budget, never reaches
    /// `.escalated`, and is held silently. Both are past the floor, so only the
    /// wait can explain the choice.
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

    /// A stall retried moments ago is left alone AND is not reported as escalated,
    /// because the brain is still handling it. The two ticks below differ ONLY in
    /// their clock, so the spacing floor is the only thing that can explain the
    /// difference — and the "too soon" one sits ten minutes out, so this pins the
    /// floor's CALIBRATION rather than merely its existence.
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

        // TEN MINUTES after the last attempt and still too soon. A floor of seconds
        // — or of one minute — would retry here.
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

    /// **The floor must outlast the read it depends on.** A retry sooner than
    /// `hubFreshness` re-reads numbers the run already considers current, so it is
    /// structurally incapable of a different answer and can only burn an attempt.
    /// Asserted as a RELATION between two constants rather than `== 900`: pinning
    /// the number restates the source, this restates the reason and fails if
    /// either side moves out from under the other.
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

    /// An `.opCompleted` naming a FOREIGN step must not refund the budget. The
    /// audit entry is stamped with the step the command ISSUED from and back-dated,
    /// so one naming `travelling` can legitimately sort after the move to
    /// `confirming`. Here it sits between two spent resolutions: if it ended the
    /// walk this directive reads as having spent 1 instead of 2 and gets an extra
    /// retry every tick, for free, in the unsafe direction.
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

    /// An operator's own resolution counts against the budget: a person who just
    /// retried by hand and watched it re-stall does not need the brain piling
    /// automated retries on the same loop. A `Skipped` summary rather than
    /// `Retried` is the case that matters — an implementation string-matching the
    /// display summary counts 0 here and hands out a full budget.
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

    /// The exact set the brain hands back to the operator rather than working.
    /// Adding to it means adding a surface the operator can answer it from.
    @Test func onlyAnUnchosenEventOptionAsksForAnOperatorDecision() {
        let requests = DirectiveAttentionReason.allCases.filter { $0.brainDisposition == .decisionRequest }
        #expect(requests == [.eventOptionNotChosen])
    }

    /// A choice is not a fault, so the retry budget must never be spent on one.
    @Test func aDecisionRequestIsEscalatedWithoutARetry() {
        let stalled = stalledRelayRun(reason: .eventOptionNotChosen)
        #expect(
            Brain.stallResponse(for: stalled, log: [], now: t(0))
                == .escalated(directiveID: "D1", reason: .eventOptionNotChosen)
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
