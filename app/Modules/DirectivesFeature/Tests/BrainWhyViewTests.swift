//
//  BrainWhyViewTests.swift
//  Replicould — Directives feature
//
//  `BrainWhy.from(report:)` is the brain's derived why-view model: it projects
//  the `BrainReport` the engine publishes every tick into graph-fact text an
//  operator reads directly, never a score.
//
//  Three things here are load-bearing beyond "the strings look right":
//
//    • `isEscalated` — an idle brain must read as calm-but-surfaced, a stalled
//      one as surfaced AND escalated (robustness bar clause 6). They must not
//      look alike, and a deferral must not creep into looking like a stall.
//    • A recent 429 must surface DISTINCTLY from self-throttling. Asserted on
//      `BrainWhyPressure.Kind`, structurally, not by matching prose — a test
//      that only compared strings would pass on a build that rendered both as
//      the same kind of line.
//    • Designations are tagged for monospace even when embedded mid-sentence
//      (the house rule Task 5's review flagged this surface for).
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameDatabase
import GameModels
import Sharing
import Testing
@testable import DirectivesFeature

/// The exact sentence `Brain.rationale(for:)` produces for the `vega` fixture.
/// Spelled out rather than computed so these tests pin the WORDING an operator
/// sees, and would fail if the engine's phrasing drifted.
private let vegaRationale = "meshing VEGA — 3,200 units, 1 hop"

@Suite("BrainWhy")
struct BrainWhyViewTests {
    // MARK: - Fixtures

    static let now = Date(timeIntervalSince1970: 1_000_000)

    /// A one-hop salvage candidate whose value sits at the hop itself.
    static let vega = GrowCandidate(
        firstHop: "VEGA",
        completesNow: true,
        relaysRemaining: 1,
        bestTier: .salvage,
        magnitudeAtTier: 3200,
        hopDistance: 4.2,
        servedTargets: ["VEGA"],
        designation: "VEGA"
    )

    /// A two-hop belt candidate whose value sits BEYOND the hop — the case
    /// that makes `servedTargets` worth rendering at all.
    static let polarisum = GrowCandidate(
        firstHop: "POLARISUM",
        completesNow: false,
        relaysRemaining: 2,
        bestTier: .richBelt,
        magnitudeAtTier: 2,
        hopDistance: 9.1,
        servedTargets: ["ALTAIR", "POLARISUM"],
        designation: "POLARISUM"
    )

    /// Limits with plenty of room, a FRESH census reading, and no 429 — the
    /// "nothing to see here" baseline every test that isn't about limits
    /// builds on. `hubStockFetchedAt: now` matters: a nil or old timestamp
    /// would make every one of those tests read a veto instead.
    static func calmLimits(rateLimitedAt: Date? = nil) -> BrainLimits {
        BrainLimits(
            actionsRemaining: 54,
            actionsLimit: 60,
            actionsFloor: 6,
            hubStock: 41_000,
            hubStockFetchedAt: now,
            spendFloor: 35_078,
            rateLimitedAt: rateLimitedAt
        )
    }

    /// A survey idle for the same reason `theHubDesignationInAnIdleGateIsTagged`
    /// tests picks for the grow gate — irrelevant to every test that isn't
    /// about survey, so it stays a quiet default.
    static let idleSurvey = BrainSurveyStatus.idle(reason: "no vessel is tagged auto:survey")

    static func report(
        _ decision: BrainDecision,
        ranked: [GrowCandidate] = [],
        hubLocation: String? = "SOL-3",
        limits: BrainLimits = calmLimits(),
        prune: BrainPrune? = nil,
        survey: BrainSurveyStatus = idleSurvey,
        observedAt: Date = now
    ) -> BrainReport {
        BrainReport(
            decision: decision,
            ranked: ranked,
            hubLocation: hubLocation,
            limits: limits,
            prune: prune,
            survey: survey,
            observedAt: observedAt
        )
    }

    /// A spare relay standing 7.07 ly from the plant site — the one the brain's
    /// own reclaim fixtures use, so the wording pinned below is the wording an
    /// operator would really see.
    static let deadend = ReclaimableRelay(deviceCode: "R9", system: "DEADEND")
    /// A second spare, far enough out that no grow will ever fetch it.
    static let outback = ReclaimableRelay(deviceCode: "R4", system: "OUTBACK")

    static func pruneFacts(
        reclaimed: BrainReclaim? = nil,
        claimed: [ReclaimableRelay] = [],
        spare: [ReclaimableRelay] = [],
        pinnedCount: Int = 4,
        declined: PruneDeclineReason? = nil
    ) -> BrainPrune {
        BrainPrune(
            reclaimed: reclaimed, claimed: claimed, spare: spare,
            pinnedCount: pinnedCount, declined: declined
        )
    }

    // MARK: - The gate

    @Test func idleIsSurfacedButNotEscalated() {
        let why = BrainWhy.from(report: Self.report(.idle(reason: "no grow or prune work")))
        #expect(why.gateText == "idle — no grow or prune work")
        #expect(why.candidates.isEmpty)
        #expect(!why.isEscalated) // idle-calm must NOT read as a stall (clause 6)
    }

    /// The brief's step 1, first half: a dispatch decision renders the top
    /// candidate's rationale as the gate, and lists the runners-up as rows.
    @Test func dispatchRendersTheTopCandidatesRationaleAsTheGate() {
        let goal = Goal(kind: .tendMesh, target: "VEGA", rationale: vegaRationale)
        let why = BrainWhy.from(
            report: Self.report(
                .dispatch(goal, ranked: [Self.vega, Self.polarisum]),
                ranked: [Self.vega, Self.polarisum]
            )
        )
        #expect(why.gateText == "launched — meshing VEGA — 3,200 units, 1 hop")
        #expect(!why.isEscalated)
        #expect(why.candidates.map(\.target) == ["VEGA", "POLARISUM"])
        #expect(why.candidates.map(\.isChosen) == [true, false])
    }

    @Test func stallIsSurfacedAndEscalated() {
        let why = BrainWhy.from(report: Self.report(.stall(.relayActivationFailed)))
        #expect(why.gateText == "stalled — \(DirectiveAttentionReason.relayActivationFailed.displayName)")
        #expect(why.isEscalated)
    }

    /// A deferral is folded into `.idle` by the engine (Task 18), but it is a
    /// different state to an operator — "we chose not to, and here is what
    /// changed under us". It must not be prefixed as though nothing was
    /// available, and it must not escalate.
    @Test func aDeferralReadsAsItsOwnGateNotAsAnOrdinaryIdle() {
        let why = BrainWhy.from(
            report: Self.report(.idle(reason: "\(BrainDecision.deferralPrefix)VEGA already in flight on confirm"))
        )
        #expect(why.gateText == "deferred — VEGA already in flight on confirm")
        #expect(!why.gateText.hasPrefix("idle"))
        #expect(!why.isEscalated)
    }

    /// The four gate states the design names must all read differently. Pinned
    /// as a set so a build that collapsed any two of them fails here rather
    /// than in a screenshot.
    @Test func theFourGateStatesAllReadDifferently() {
        let goal = Goal(kind: .tendMesh, target: "VEGA", rationale: vegaRationale)
        let gates = [
            BrainWhy.from(report: Self.report(.dispatch(goal, ranked: [Self.vega]), ranked: [Self.vega])),
            BrainWhy.from(
                report: Self.report(
                    .idle(reason: "\(BrainDecision.deferralPrefix)carrier HV01 unavailable on confirm")
                )
            ),
            BrainWhy.from(report: Self.report(.idle(reason: "no grow or prune work"))),
            BrainWhy.from(report: Self.report(.stall(.printStockShort))),
        ]
        #expect(Set(gates.map(\.gateText)).count == 4)
        // Only the stall escalates — the clause-6 distinction, over all four
        // states at once rather than one test per state.
        #expect(gates.map(\.isEscalated) == [false, false, false, true])
    }

    // MARK: - Ranked candidates

    /// Rank order is the brain's order, and every row is a graph fact: what
    /// the hop unlocks, in the winning tier's own units, plus the chain
    /// length. A hop whose value sits beyond it names where.
    @Test func candidatesRenderInRankOrderWithTheirGraphFacts() {
        let why = BrainWhy.from(
            report: Self.report(.idle(reason: "no free carrier at SOL-3"), ranked: [Self.vega, Self.polarisum])
        )
        #expect(why.candidates.map(\.rank) == [1, 2])
        #expect(why.candidates.map(\.target) == ["VEGA", "POLARISUM"])
        #expect(why.candidates.map(\.fact) == ["3,200 units · 1 hop", "2 rich belts · 2 hops"])
        // The hop itself is never repeated in its own served list.
        #expect(why.candidates.map(\.servedTargets) == [[], ["ALTAIR"]])
        // A tick that launched nothing has no chosen row.
        #expect(why.candidates.allSatisfy { !$0.isChosen })
    }

    /// The candidate list is not a launch-only surface: the ticks an operator
    /// most needs explained are the ones that DIDN'T launch.
    @Test func candidatesAreShownOnATickThatLaunchedNothing() {
        let why = BrainWhy.from(
            report: Self.report(
                .idle(reason: "every grow candidate is already in flight"),
                ranked: [Self.vega, Self.polarisum]
            )
        )
        #expect(why.candidates.count == 2)
    }

    /// The ranked field is one entry per reachable first hop and can run to
    /// dozens. It used to be capped at five with the remainder counted, because
    /// the report was pinned ABOVE the Directives list and would have pushed the
    /// rows it explains off screen. It now renders in a scrolling detail pane,
    /// so the whole field is projected and the operator can read all of it.
    @Test func theWholeRankedFieldIsProjected() {
        let field = (1...12).map { index in
            GrowCandidate(
                firstHop: "SYS\(index)",
                completesNow: false,
                relaysRemaining: index,
                bestTier: .salvage,
                magnitudeAtTier: Double(index),
                hopDistance: Double(index),
                servedTargets: ["SYS\(index)"],
                designation: "SYS\(index)"
            )
        }
        let why = BrainWhy.from(
            report: Self.report(.idle(reason: "no free carrier at SOL-3"), ranked: field)
        )
        #expect(why.candidates.count == field.count)
        #expect(why.candidates.map(\.rank) == Array(1...12))
    }

    /// The row the gate is talking about is always in the field, at its true
    /// rank.
    ///
    /// `Brain.plan` launches the best candidate NOT already in flight, which
    /// need not be rank 1 — with several grows already flying it can sit well
    /// down the field. While the field was capped this needed a displacement
    /// rule to stop the card contradicting its own headline; uncapped it falls
    /// out for free, and this pins that the headline and its row still agree.
    @Test func theLaunchedCandidateIsListedAtItsTrueRank() {
        let field = (1...12).map { index in
            GrowCandidate(
                firstHop: "SYS\(index)",
                completesNow: false,
                relaysRemaining: index,
                bestTier: .salvage,
                magnitudeAtTier: Double(index),
                hopDistance: Double(index),
                servedTargets: ["SYS\(index)"],
                designation: "SYS\(index)"
            )
        }
        // Ranks 1–8 are already in flight, so the brain launched rank 9.
        let goal = Goal(kind: .tendMesh, target: "SYS9", rationale: "meshing SYS9 — 9 units, 9 hops")
        let why = BrainWhy.from(report: Self.report(.dispatch(goal, ranked: field), ranked: field))

        #expect(why.candidates.count == field.count)
        let chosen = why.candidates.first { $0.isChosen }
        #expect(chosen?.target == "SYS9")
        #expect(chosen?.rank == 9, "the launched row keeps its true rank")
        #expect(why.candidates.count(where: \.isChosen) == 1, "exactly one row is the chosen one")
        // The gate names it, and so does a row.
        #expect(why.gateText.contains("SYS9"))
    }

    /// Rank order is the field's own order, and `isChosen` marks the launched
    /// row wherever it sits — including near the top.
    @Test func aChosenRowNearTheTopKeepsItsPlace() {
        let field = (1...8).map { index in
            GrowCandidate(
                firstHop: "SYS\(index)", completesNow: false, relaysRemaining: index,
                bestTier: .salvage, magnitudeAtTier: Double(index), hopDistance: Double(index),
                servedTargets: ["SYS\(index)"], designation: "SYS\(index)"
            )
        }
        let goal = Goal(kind: .tendMesh, target: "SYS2", rationale: "meshing SYS2 — 2 units, 2 hops")
        let why = BrainWhy.from(report: Self.report(.dispatch(goal, ranked: field), ranked: field))

        #expect(why.candidates.map(\.target) == (1...8).map { "SYS\($0)" })
        #expect(why.candidates.map(\.isChosen) == [false, true, false, false, false, false, false, false])
    }

    // MARK: - Limit pressure

    /// The design's "limits are signals" clause: a 429 is the SERVER refusing
    /// us; self-throttling is us pacing ourselves. Asserted on the typed kind,
    /// so a build that rendered them as one kind of line fails here.
    @Test func aRecent429SurfacesDistinctlyFromSelfThrottling() {
        let throttled = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                limits: BrainLimits(
                    actionsRemaining: 4, actionsLimit: 60, actionsFloor: 6,
                    hubStock: 41_000, hubStockFetchedAt: Self.now,
                    spendFloor: 35_078, rateLimitedAt: nil
                )
            )
        )
        let rateLimited = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                limits: Self.calmLimits(rateLimitedAt: Self.now.addingTimeInterval(-120))
            )
        )

        // Self-throttling reports the governor and nothing more: we are not
        // being rate-limited, and saying so would be false.
        #expect(!throttled.limitPressure.contains { $0.kind == .rateLimited })
        #expect(throttled.limitPressure.contains { $0.kind == .governor })

        // A 429 gets its OWN line, of its own kind, marked as imposed rather
        // than chosen — and does not merely re-word the governor line.
        let imposed = rateLimited.limitPressure.filter { $0.kind == .rateLimited }
        #expect(imposed.count == 1)
        #expect(imposed.first?.isImposed == true)
        #expect(rateLimited.limitPressure.contains { $0.kind == .governor })
        #expect(imposed.first?.detail != rateLimited.limitPressure.first { $0.kind == .governor }?.detail)
    }

    /// A 429 from an hour ago is history, not pressure. Without a window the
    /// line would sit there for the rest of the session and stop meaning
    /// anything.
    @Test func anOld429IsNotReportedAsCurrentPressure() {
        let why = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                limits: Self.calmLimits(rateLimitedAt: Self.now.addingTimeInterval(-3600))
            )
        )
        #expect(!why.limitPressure.contains { $0.kind == .rateLimited })
    }

    /// The governor line states both halves of the fact — what is left, and
    /// where we stop ourselves — so "4 left" is readable as pressure rather
    /// than as a number without a scale.
    @Test func theGovernorLineNamesTheFloorItPacesAgainst() {
        let why = BrainWhy.from(report: Self.report(.idle(reason: "no grow or prune work")))
        let governor = why.limitPressure.first { $0.kind == .governor }
        #expect(governor?.detail == "commands — 54 of 60 left this minute, pacing ourselves below 6")
    }

    /// The reserve-floor line reports ALL FOUR states the rail has — clear,
    /// below floor, **stale**, and unread — not just the two a bare figure can
    /// express.
    ///
    /// The staleness case is the one this test exists for. `RelayRun
    /// .printStockIsShort` vetoes on a census row older than
    /// `RelayRun.hubFreshness` regardless of how healthy the number looks, so
    /// a card rendering an hour-old 41,000-unit reading as "against a 35,078
    /// reserve floor" would be telling the operator there is headroom while
    /// every print is in fact being refused. Silence must not read as
    /// permission to spend — and neither must a stale reading, which is the
    /// same failure wearing a number.
    @Test func theReserveFloorLineReportsAllThreeVetoStatesNotJustTwo() {
        func line(hubStock: Int?, fetchedAt: Date?) -> String? {
            BrainWhy.from(
                report: Self.report(
                    .idle(reason: "no grow or prune work"),
                    limits: BrainLimits(
                        actionsRemaining: 54, actionsLimit: 60, actionsFloor: 6,
                        hubStock: hubStock, hubStockFetchedAt: fetchedAt,
                        spendFloor: 35_078, rateLimitedAt: nil
                    )
                )
            ).limitPressure.first { $0.kind == .reserveFloor }?.detail
        }
        let fresh = Self.now.addingTimeInterval(-60)
        let stale = Self.now.addingTimeInterval(-3720) // 62 minutes — well past hubFreshness

        #expect(
            line(hubStock: 41_000, fetchedAt: fresh)
                == "hub stock — 41,000 units against a 35,078 reserve floor"
        )
        #expect(
            line(hubStock: 12_000, fetchedAt: fresh)
                == "hub stock — 12,000 units, below the 35,078 reserve floor — printing vetoed"
        )
        // Comfortably ABOVE the floor and still vetoed — the whole point. The
        // line names the AGE, not the figure, so the operator looks at the
        // census rather than hunting a shortage that does not exist.
        #expect(
            line(hubStock: 41_000, fetchedAt: stale)
                == "hub stock — 41,000 units, but the census reading is 1h old — printing vetoed until it refreshes"
        )
        #expect(
            line(hubStock: nil, fetchedAt: nil)
                == "hub stock — no census reading — printing vetoed until one lands"
        )
    }

    /// The rail's own freshness bound is what decides, not a number retyped in
    /// the feature — one second either side of `RelayRun.hubFreshness` flips
    /// the verdict.
    @Test func stalenessIsJudgedAgainstTheRailsOwnFreshnessBound() {
        func standing(ageSeconds: TimeInterval) -> BrainLimits.HubStockStanding {
            BrainLimits(
                actionsRemaining: 54, actionsLimit: 60, actionsFloor: 6,
                hubStock: 41_000, hubStockFetchedAt: Self.now.addingTimeInterval(-ageSeconds),
                spendFloor: 35_078, rateLimitedAt: nil
            ).hubStockStanding(at: Self.now)
        }
        #expect(standing(ageSeconds: RelayRun.hubFreshness - 1) == .clear)
        #expect(standing(ageSeconds: RelayRun.hubFreshness) == .clear) // the bound itself is `>`, not `>=`
        #expect(standing(ageSeconds: RelayRun.hubFreshness + 1) == .stale(age: RelayRun.hubFreshness + 1))
    }

    // MARK: - Prune

    /// The brief's step 1, first half. A reclaim is a GRAPH FACT, in the same
    /// voice the gate and the candidate rows already speak: which relay, where
    /// it stands, how far that is from the system it is going to, and what it
    /// costs. Never a score, and checkable against the map.
    ///
    /// The span split is asserted too, because it carries the house monospace
    /// rule: `DEADEND` and `VEGA` are designations and render mono, while `R9`
    /// — a DEVICE code, which the rule does not govern (`BrainWhySpan`'s
    /// header) — stays prose.
    @Test func aReclaimRendersAsANonEscalatedGraphFact() {
        let goal = Goal(kind: .tendMesh, target: "VEGA", rationale: vegaRationale)
        let why = BrainWhy.from(
            report: Self.report(
                .dispatch(goal, ranked: [Self.vega]),
                ranked: [Self.vega],
                prune: Self.pruneFacts(
                    reclaimed: BrainReclaim(
                        deviceCode: "R9", fromSystem: "DEADEND", toSystem: "VEGA", distanceLY: 7.071
                    )
                )
            )
        )
        #expect(why.pruneNotes.map(\.kind) == [.reclaimed])
        #expect(
            why.pruneNotes.first?.text
                == "reclaiming R9 from DEADEND — 7.1 ly to VEGA, no resources spent"
        )
        #expect(why.pruneNotes.first?.spans == [
            .prose("reclaiming R9 from "),
            .designation("DEADEND"),
            .prose(" — 7.1 ly to "),
            .designation("VEGA"),
            .prose(", no resources spent"),
        ])
        #expect(!why.isEscalated)
    }

    /// Clause 6 on the prune side. A useless relay the brain has NOT reclaimed
    /// is surfaced-CALM: there is no prune stall path at all, because "there is
    /// a spare relay I haven't reused yet" is never a problem needing an
    /// operator. So the note reads as an observation, and `isEscalated` stays
    /// false.
    @Test func aUselessRelayLeftInPlaceIsIdleCalmNotAStall() {
        let why = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                prune: Self.pruneFacts(spare: [Self.deadend])
            )
        )
        #expect(why.isEscalated == false)
        #expect(why.pruneNotes.map(\.kind) == [.spare])
        #expect(why.pruneNotes.first?.isObservation == true)
        #expect(
            why.pruneNotes.first?.text
                == "1 relay spare at DEADEND — on no road the mesh needs, kept for the next grow"
        )
        #expect(why.pruneNotes.first?.spans.contains(.designation("DEADEND")) == true)
    }

    /// A tick can do both, and the two facts must not swallow each other: the
    /// reclaim it took, and the spares it left standing.
    @Test func aReclaimAndTheSparesLeftBehindAreBothReported() {
        let goal = Goal(kind: .tendMesh, target: "VEGA", rationale: vegaRationale)
        let why = BrainWhy.from(
            report: Self.report(
                .dispatch(goal, ranked: [Self.vega]),
                ranked: [Self.vega],
                prune: Self.pruneFacts(
                    reclaimed: BrainReclaim(
                        deviceCode: "R9", fromSystem: "DEADEND", toSystem: "VEGA", distanceLY: 7.071
                    ),
                    spare: [Self.outback]
                )
            )
        )
        #expect(why.pruneNotes.map(\.kind) == [.reclaimed, .spare])
        #expect(why.pruneNotes.last?.text.contains("OUTBACK") == true)
        #expect(!why.isEscalated)
    }

    /// **The in-flight window.** A source relay stays deployed and `relaying`
    /// for the whole outbound leg of the run coming to fetch it — hundreds of
    /// 5-second ticks — and `PrunePredicate`, stateless, keeps returning it as
    /// reclaimable the entire time. So the card must not describe prune's one
    /// action correctly for the tick that launched it and wrongly for the rest
    /// of its lifetime.
    ///
    /// Both wrong answers are asserted against, because both are tempting:
    /// leaving it in `spare` says "kept for the next grow" about a relay
    /// already taken, and merely suppressing it falls through to "nothing
    /// spare" about a mesh that has a loose relay in it.
    @Test func aRelayAlreadyBeingCollectedIsNotOfferedAsSpare() {
        let why = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                prune: Self.pruneFacts(claimed: [Self.deadend])
            )
        )
        #expect(why.pruneNotes.map(\.kind) == [.claimed])
        #expect(
            why.pruneNotes.first?.text
                == "1 relay already claimed at DEADEND — collection already under way"
        )
        #expect(why.pruneNotes.first?.text.contains("kept for the next grow") == false)
        // Not folded into either neighbour: the mesh is neither offering it
        // nor tight.
        #expect(!why.pruneNotes.contains { $0.kind == .spare || $0.kind == .pinned })
        // It is the same action `.reclaimed` announced, still under way, so it
        // keeps that weight rather than dropping to an observation.
        #expect(why.pruneNotes.first?.isObservation == false)
        #expect(!why.isEscalated)
    }

    /// A tick can be in all three prune states at once: one relay taken now,
    /// one already on its way out from an earlier tick, one still loose. Each
    /// gets its own line and none absorbs another.
    @Test func aTickReportsWhatItTookWhatIsUnderWayAndWhatIsLeft() {
        let goal = Goal(kind: .tendMesh, target: "VEGA", rationale: vegaRationale)
        let why = BrainWhy.from(
            report: Self.report(
                .dispatch(goal, ranked: [Self.vega]),
                ranked: [Self.vega],
                prune: Self.pruneFacts(
                    reclaimed: BrainReclaim(
                        deviceCode: "R9", fromSystem: "DEADEND", toSystem: "VEGA", distanceLY: 7.071
                    ),
                    claimed: [ReclaimableRelay(deviceCode: "R2", system: "PROXIMA")],
                    spare: [Self.outback]
                )
            )
        )
        #expect(why.pruneNotes.map(\.kind) == [.reclaimed, .claimed, .spare])
        #expect(why.pruneNotes.map(\.text) == [
            "reclaiming R9 from DEADEND — 7.1 ly to VEGA, no resources spent",
            "1 relay already claimed at PROXIMA — collection already under way",
            "1 relay spare at OUTBACK — on no road the mesh needs, kept for the next grow",
        ])
        #expect(!why.isEscalated)
    }

    /// **The distinction a prior review called out.** `PrunePredicate` returns
    /// an all-pinned partition BOTH when the census cannot place the systems it
    /// depends on and when every relay is genuinely load-bearing — the two were
    /// byte-identical before `declined` was added. "I can't judge right now"
    /// and "nothing is spare" are different facts with different fixes, and
    /// this surface must not conflate them.
    ///
    /// Asserted on the typed KIND as well as the wording, the same discipline
    /// `BrainWhyPressure` uses: a build that rendered both as one kind of line
    /// fails here rather than in a screenshot.
    @Test func decliningToJudgeReadsDifferentlyFromNothingBeingSpare() {
        let declined = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                prune: Self.pruneFacts(declined: .censusIncomplete(systems: ["GHOST"]))
            )
        )
        let judged = BrainWhy.from(
            report: Self.report(.idle(reason: "no grow or prune work"), prune: Self.pruneFacts())
        )

        #expect(declined.pruneNotes.map(\.kind) == [.declined])
        #expect(judged.pruneNotes.map(\.kind) == [.pinned])
        #expect(declined.pruneNotes.first?.text != judged.pruneNotes.first?.text)
        #expect(
            declined.pruneNotes.first?.text
                == "prune stood down — the census cannot place GHOST, so every relay stays pinned"
        )
        #expect(
            judged.pruneNotes.first?.text == "nothing spare — 4 relays pinned on the roads the mesh needs"
        )
        // Neither is a problem an operator must fix, so neither escalates.
        #expect(!declined.isEscalated)
        #expect(!judged.isEscalated)
    }

    /// The two decline reasons have different fixes — mesh the hub, versus wait
    /// for the census to catch up — so they must not collapse into one line.
    @Test func theTwoDeclineReasonsReadDifferently() {
        func text(_ reason: PruneDeclineReason) -> String? {
            BrainWhy.from(
                report: Self.report(
                    .idle(reason: "no grow or prune work"), prune: Self.pruneFacts(declined: reason)
                )
            ).pruneNotes.first?.text
        }
        #expect(
            text(.noAnchor)
                == "prune stood down — no print hub on the mesh to judge from, so every relay stays pinned"
        )
        #expect(text(.noAnchor) != text(.censusIncomplete(systems: ["GHOST"])))
    }

    /// `censusIncomplete(systems:)` is UNBOUNDED — after a database reset it can
    /// carry every mesh and target system at once — so the note names a few and
    /// counts the rest rather than turning a one-line observation into the whole
    /// card. Same judgement `hiddenCandidates` makes about the ranked field.
    @Test func aLongCensusIncompleteListIsCappedAndTheRemainderCounted() {
        let why = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                prune: Self.pruneFacts(declined: .censusIncomplete(systems: (1...40).map { "SYS\($0)" }))
            )
        )
        let note = why.pruneNotes.first
        #expect(note?.kind == .declined)
        #expect(note?.spans.filter(\.isDesignation).count == BrainWhy.maxNamedSystems)
        #expect(
            note?.text == """
                prune stood down — the census cannot place SYS1, SYS2, SYS3 +37 more, \
                so every relay stays pinned
                """
        )
    }

    /// The spare list is unbounded for the same reason and gets the same cap.
    @Test func aLongSpareListIsCappedAndTheRemainderCounted() {
        let spares = (1...9).map { ReclaimableRelay(deviceCode: "R\($0)", system: "SYS\($0)") }
        let why = BrainWhy.from(
            report: Self.report(.idle(reason: "no grow or prune work"), prune: Self.pruneFacts(spare: spares))
        )
        #expect(why.pruneNotes.first?.spans.filter(\.isDesignation).count == BrainWhy.maxNamedSystems)
        #expect(
            why.pruneNotes.first?.text == """
                9 relays spare at SYS1, SYS2, SYS3 +6 more — on no road the mesh needs, \
                kept for the next grow
                """
        )
    }

    /// Two spares in one system name it once. The count is of RELAYS and the
    /// list is of PLACES — repeating a designation would read as a mistake.
    @Test func twoSparesInOneSystemNameThatSystemOnce() {
        let why = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                prune: Self.pruneFacts(
                    spare: [
                        ReclaimableRelay(deviceCode: "R1", system: "DEADEND"),
                        ReclaimableRelay(deviceCode: "R2", system: "DEADEND"),
                    ]
                )
            )
        )
        #expect(
            why.pruneNotes.first?.text
                == "2 relays spare at DEADEND — on no road the mesh needs, kept for the next grow"
        )
    }

    /// **Prune has no stall path, in any state it can be in.** Growth can halt
    /// and need an operator; prune cannot. Swept over every note kind at once,
    /// with the coverage of the sweep itself asserted, so a kind added later
    /// cannot quietly escape it.
    @Test func noPruneStateEverEscalates() {
        let states: [BrainPrune] = [
            Self.pruneFacts(
                reclaimed: BrainReclaim(
                    deviceCode: "R9", fromSystem: "DEADEND", toSystem: "VEGA", distanceLY: 7.071
                )
            ),
            Self.pruneFacts(claimed: [Self.deadend]),
            Self.pruneFacts(spare: [Self.deadend]),
            Self.pruneFacts(),
            Self.pruneFacts(declined: .noAnchor),
            Self.pruneFacts(declined: .censusIncomplete(systems: ["GHOST"])),
        ]
        var seen: Set<BrainWhyPruneNote.Kind> = []
        for state in states {
            let why = BrainWhy.from(
                report: Self.report(.idle(reason: "no grow or prune work"), prune: state)
            )
            #expect(!why.isEscalated, "prune must never escalate — \(state)")
            #expect(!why.pruneNotes.isEmpty, "every prune state says something — \(state)")
            seen.formUnion(why.pruneNotes.map(\.kind))
        }
        #expect(seen == Set(BrainWhyPruneNote.Kind.allCases))
    }

    /// The pairing the sweep above cannot make: prune never escalates, but it
    /// must not SUPPRESS an escalation either, and its notes must still render
    /// on a stalled tick.
    ///
    /// `noPruneStateEverEscalates` only ever drives `.idle`, so on its own it
    /// is equally satisfied by a build where `isEscalated` is hard-wired false.
    /// This is the other half: same prune facts, a `.stall` decision, and both
    /// halves of the card still correct.
    @Test func aStallStillEscalatesWithPruneNotesBesideIt() {
        let why = BrainWhy.from(
            report: Self.report(
                .stall(.relayActivationFailed), prune: Self.pruneFacts(spare: [Self.deadend])
            )
        )
        #expect(why.isEscalated, "the stall still escalates — prune does not calm it down")
        #expect(why.pruneNotes.map(\.kind) == [.spare], "and prune still speaks on a stalled tick")
        #expect(why.pruneNotes.first?.isObservation == true)
    }

    /// A tick that never got as far as judging — no mesh yet, or a world read
    /// that failed — says NOTHING about prune. Silence is honest there; a
    /// "nothing spare" line would claim a tidy mesh nobody looked at.
    @Test func aTickThatDidNotJudgeSaysNothingAboutPrune() {
        let why = BrainWhy.from(report: Self.report(.idle(reason: "no mesh yet")))
        #expect(why.pruneNotes.isEmpty)
    }

    // MARK: - Survey

    /// The brief's headline case: a published report carries the verdict
    /// through, ready or idle-with-reason, as its OWN field — never folded
    /// into `topGoalGate`, which answers a different question.
    @Test func theReportCarriesTheSurveyVerdictReadyOrIdle() {
        let ready = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .ready(carrier: "V1", roamCentre: "AINALRAM")
            )
        )
        #expect(ready.survey.kind == .ready)
        #expect(ready.survey.text == "ready to roam from AINALRAM — carrier V1")

        let idle = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .idle(reason: "no vessel is tagged auto:survey")
            )
        )
        #expect(idle.survey.kind == .idle)
        #expect(idle.survey.text == "no vessel is tagged auto:survey")
    }

    /// A ready verdict and a live run must not read the same, and the kind is
    /// what a build cannot fake past — a wording slip that happened to leave
    /// the two sentences equal would still be caught here.
    @Test func aReadySurveyAndALaunchedSurveyDoNotReadIdentically() {
        let ready = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .ready(carrier: "V1", roamCentre: "AINALRAM")
            )
        )
        let launched = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .launched(carrier: "V1", roamCentre: "AINALRAM", status: .running)
            )
        )
        #expect(ready.survey.kind != launched.survey.kind)
        #expect(ready.survey.text != launched.survey.text)
        #expect(launched.survey.text == "roaming from AINALRAM — carrier V1")
    }

    /// A fixed-target run's live row carries no `roamCentre`; the card must
    /// say what it IS doing, never substitute a fake designation —
    /// `"unknown"` is not a real place.
    @Test func aFixedTargetSurveyNamesNoCentreRatherThanAFakeOne() {
        let why = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .launched(carrier: "V1", roamCentre: nil, status: .running)
            )
        )
        #expect(why.survey.text == "surveying a fixed target queue — carrier V1")
        #expect(!why.survey.spans.contains { $0.isDesignation })
        #expect(!why.survey.text.contains("unknown"))
    }

    /// `.needsAttention`/`.paused` are both live, but a card rendering all
    /// three alike would tell an operator a stalled survey is roaming — each
    /// must read apart, and paused must not read as a fault.
    @Test func theThreeLaunchedStatusesRenderDistinguishably() {
        let running = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .launched(carrier: "V1", roamCentre: "AINALRAM", status: .running)
            )
        ).survey
        let halted = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .launched(carrier: "V1", roamCentre: "AINALRAM", status: .needsAttention)
            )
        ).survey
        let paused = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .launched(carrier: "V1", roamCentre: "AINALRAM", status: .paused)
            )
        ).survey

        #expect(Set([running.kind, halted.kind, paused.kind]).count == 3)
        #expect(Set([running.text, halted.text, paused.text]).count == 3)
        #expect(running.text == "roaming from AINALRAM — carrier V1")
        #expect(halted.text == "halted, roam centre AINALRAM — carrier V1")
        #expect(paused.text == "paused, roam centre AINALRAM — carrier V1")
        // A deliberate pause is not a fault: it must not borrow halted's word.
        #expect(!paused.text.contains("halted"))
        #expect(!paused.text.contains("attention"))
        // The centre is still the only mono span — "roam centre" is prose.
        #expect(halted.spans == [
            .prose("halted, roam centre "), .designation("AINALRAM"), .prose(" — carrier V1"),
        ])
    }

    /// The three named idle reasons an operator must be able to tell apart
    /// without opening the log — pinned as a set, the same discipline
    /// `theFourGateStatesAllReadDifferently` applies to the grow gate.
    @Test func theThreeIdleReasonsRenderDistinguishably() {
        let reasons = [
            "no vessel is tagged auto:survey",
            "V1 has no survey controller aboard",
            "roam centre AINALRAM is not in the census",
        ]
        let lines = reasons.map { reason in
            BrainWhy.from(
                report: Self.report(.idle(reason: "no grow or prune work"), survey: .idle(reason: reason))
            ).survey
        }
        #expect(Set(lines.map(\.text)).count == 3)
        #expect(lines.allSatisfy { $0.kind == .idle })
    }

    /// Never paraphrased: the idle line is Task 1's own reason string, so the
    /// screen and the log cannot disagree about why nothing launched.
    @Test func theIdleSurveyReasonIsCarriedVerbatim() {
        let reason = "V1's controller AMI1 has adopted no drone aboard"
        let why = BrainWhy.from(
            report: Self.report(.idle(reason: "no grow or prune work"), survey: .idle(reason: reason))
        )
        #expect(why.survey.text == reason)
    }

    /// The roam centre is a location designation, so it renders mono even
    /// where it is embedded in an idle sentence rather than standing alone —
    /// the same rule `designationsEmbeddedInTheGateAreTaggedForMonospace`
    /// pins for the grow gate.
    @Test func theRoamCentreIsTaggedForMonospaceEverywhereItAppears() {
        let ready = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                survey: .ready(carrier: "V1", roamCentre: "AINALRAM")
            )
        )
        #expect(ready.survey.spans == [
            .prose("ready to roam from "), .designation("AINALRAM"), .prose(" — carrier V1"),
        ])

        let idle = BrainWhy.from(
            report: Self.report(
                .idle(reason: "no grow or prune work"),
                hubLocation: "AINALRAM-BELT-1",
                survey: .idle(reason: "roam centre AINALRAM is not in the census")
            )
        )
        #expect(idle.survey.spans == [
            .prose("roam centre "), .designation("AINALRAM"), .prose(" is not in the census"),
        ])
        // The carrier is a DEVICE code, never governed by the monospace rule.
        #expect(!ready.survey.spans.contains(.designation("V1")))
    }

    /// Survey has no stall path (mirrors `SurveyReadiness`'s own two cases),
    /// so nothing about it can flip the card's temperature — the same
    /// argument `noPruneStateEverEscalates` makes for prune.
    @Test func noSurveyStateEverEscalatesAStillIdleGate() {
        for survey: BrainSurveyStatus in [
            .ready(carrier: "V1", roamCentre: "AINALRAM"),
            .launched(carrier: "V1", roamCentre: "AINALRAM", status: .running),
            .launched(carrier: "V1", roamCentre: "AINALRAM", status: .needsAttention),
            .launched(carrier: "V1", roamCentre: "AINALRAM", status: .paused),
            .launched(carrier: "V1", roamCentre: nil, status: .running),
            .idle(reason: "no vessel is tagged auto:survey"),
        ] {
            let why = BrainWhy.from(
                report: Self.report(.idle(reason: "no grow or prune work"), survey: survey)
            )
            #expect(!why.isEscalated, "survey must never escalate — \(survey)")
        }
    }

    // MARK: - Monospace for embedded designations

    /// The house rule, applied to a sentence rather than a standalone label:
    /// the designations inside the gate come back tagged so the view can put
    /// them in a mono token, and the prose around them does not.
    @Test func designationsEmbeddedInTheGateAreTaggedForMonospace() {
        let goal = Goal(
            kind: .tendMesh, target: "POLARISUM",
            rationale: "meshing POLARISUM — 2 rich belts at ALTAIR, 2 hops"
        )
        let why = BrainWhy.from(
            report: Self.report(.dispatch(goal, ranked: [Self.polarisum]), ranked: [Self.polarisum])
        )
        #expect(why.topGoalGate == [
            .prose("launched — meshing "),
            .designation("POLARISUM"),
            .prose(" — 2 rich belts at "),
            .designation("ALTAIR"),
            .prose(", 2 hops"),
        ])
    }

    /// The hub is a location designation too, and it turns up in the idle gate
    /// the brain emits most often when the fleet is busy.
    @Test func theHubDesignationInAnIdleGateIsTagged() {
        let why = BrainWhy.from(
            report: Self.report(.idle(reason: "no free carrier at SOL-3"), hubLocation: "SOL-3")
        )
        #expect(why.topGoalGate == [.prose("idle — no free carrier at "), .designation("SOL-3")])
    }

    /// The split matches codes it was TOLD, never a shape. "Out of FTL relays"
    /// is a stall's display name; "FTL" is not a star system and must stay
    /// prose — this is the concrete case that rules out an all-caps heuristic.
    @Test func anAllCapsWordThatIsNotAKnownDesignationStaysProse() {
        let why = BrainWhy.from(
            report: Self.report(.stall(.awaitingRelayRestock), ranked: [Self.vega])
        )
        #expect(why.topGoalGate == [.prose("stalled — Out of FTL relays")])
    }

    /// Longest match wins, so a system whose designation is a prefix of a
    /// location's cannot swallow it — and a code embedded inside a longer word
    /// is not a code.
    @Test func theSplitPrefersTheLongestCodeAndRespectsBoundaries() {
        #expect(
            [BrainWhySpan].spans(in: "carrier free at SOL-3, none at SOL", designations: ["SOL", "SOL-3"])
                == [
                    .prose("carrier free at "), .designation("SOL-3"),
                    .prose(", none at "), .designation("SOL"),
                ]
        )
        #expect(
            [BrainWhySpan].spans(in: "SOLARIS is not SOL", designations: ["SOL"])
                == [.prose("SOLARIS is not "), .designation("SOL")]
        )
    }
}

/// The reading end of the why-view's feed, and the reason this surface is not
/// an orphan.
///
/// Task 5 shipped `BrainWhy`/`BrainWhyRow`/`BrainWhyView` with ZERO production
/// callers, because no live `BrainDecision` reached the UI. This suite pins
/// the chain that closed it:
///
///   `DirectiveEngineCore.tickBrain()`
///     → `@Shared(.brainReport)`                (proven from the engine's end
///                                               by `BrainLoopTests`)
///     → `DirectivesFeature.State.brainReport`  (asserted here)
///     → `DirectivesFeature.State.brainWhy`     (asserted here)
///     → `DirectivesListView`'s `.safeAreaInset` (a compile-time reference —
///                                               the only step a logic test
///                                               cannot execute, and the one
///                                               the compiler checks for us)
///
/// Nothing here fakes a report: the value read is whatever was written under
/// the same shared key, through the same in-memory store the engine writes to.
@Suite("BrainWhy — reachable from the Directives surface")
@MainActor
struct BrainWhyReachabilityTests {
    /// A report published under `.brainReport` reaches the Directives
    /// reducer's state and projects into a why-view. If the `@Shared` property
    /// were dropped from `State`, or `brainWhy` stopped projecting, this fails.
    @Test func aPublishedReportReachesTheDirectivesFeaturesState() throws {
        let database = try GameDatabase.bootstrap()
        let storage = InMemoryStorage()
        let goal = Goal(kind: .tendMesh, target: "VEGA", rationale: vegaRationale)
        let published = BrainWhyViewTests.report(
            .dispatch(goal, ranked: [BrainWhyViewTests.vega]),
            ranked: [BrainWhyViewTests.vega]
        )

        withDependencies {
            $0.defaultDatabase = database
            $0.defaultInMemoryStorage = storage
        } operation: {
            @Shared(.brainReport) var report: BrainReport?
            $report.withLock { $0 = published }

            let store = TestStore(initialState: DirectivesFeature.State()) {
                DirectivesFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.defaultInMemoryStorage = storage
            }
            store.exhaustivity = .off

            #expect(store.state.brainReport == published)
            #expect(store.state.brainWhy?.gateText == "launched — meshing VEGA — 3,200 units, 1 hop")
            #expect(store.state.brainWhy?.candidates.map(\.target) == ["VEGA"])
        }
    }

    /// Before the first tick of a session there is nothing to explain, so the
    /// card must not render at all — an empty card would claim the brain had
    /// said something when it hadn't.
    @Test func noReportMeansNoCard() throws {
        let database = try GameDatabase.bootstrap()
        withDependencies {
            $0.defaultDatabase = database
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = TestStore(initialState: DirectivesFeature.State()) {
                DirectivesFeature()
            } withDependencies: {
                $0.defaultDatabase = database
            }
            store.exhaustivity = .off
            #expect(store.state.brainWhy == nil)
        }
    }
}
