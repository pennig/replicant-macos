//
//  BrainReport.swift
//  Replicould — DirectiveEngine
//
//  The live feed from the brain's plan loop to its why-view
//  (`brain-robustness-bar` clause 8: the brain must be explainable, in graph
//  facts, while it is running). Every tick `DirectiveEngineCore.tickBrain()`
//  publishes one `BrainReport`; `DirectivesFeature` reads it and projects it
//  into `BrainWhy`. Before this existed the decision was logged and dropped,
//  which left `BrainWhy`/`BrainWhyView` (Task 5) with no production caller at
//  all.
//
//  **Why `@Shared(.inMemory)` and not a table, a client closure, or engine
//  state.** The why-view is DERIVED state — it restates what the brain just
//  worked out from rows that are already persisted — so the plan's robustness
//  clause forbids giving it a table or a migration. That rules the
//  `@FetchAll`/`@Fetch` route out. The remaining house conventions for moving
//  a value from a service into a feature are a `@Dependency`-vended client and
//  the Sharing library; between them:
//
//    • Sharing is what this codebase already uses for cross-module state that
//      is NOT database-backed (`@Shared(.account)`, `@Shared(.appStorage(…))`),
//      and `.inMemory` is its own strategy for exactly "shared for the
//      lifetime of the process, persisted nowhere".
//    • The value lives in Sharing's in-memory store, NOT in
//      `DirectiveEngineCore`. The actor writes the tick's report and forgets
//      it — no field, no last-decision cache, nothing for the engine to hold
//      UI state in, and nothing for the *brain* to read back on the next tick
//      (clause 2: stateless between ticks).
//    • It is safe across the actor/main-actor boundary by construction:
//      `BrainReport` is `Sendable`, and `Shared` mutation goes through the
//      library's own lock. The engine writes off-main; the feature observes
//      on-main.
//    • It is testable without any of the plumbing an `AsyncStream` client
//      would need: `defaultInMemoryStorage` is a dependency, so a test scopes
//      its own store and asserts on what the engine published.
//

import Foundation
import GameModels
import Sharing

/// What the brain's rails had to say this tick — the "limit pressure" half of
/// the why-view (`brain-robustness-bar` clause 8, and ticket 03's spend
/// ceiling). Facts only; the wording an operator reads is the feature's job.
public struct BrainLimits: Equatable, Sendable {
    /// Actions-bucket tokens the shared `RateLimitGovernor` believes are left
    /// in this minute's window.
    public let actionsRemaining: Int
    /// That bucket's own limit (60/min for a game token).
    public let actionsLimit: Int
    /// The token count at or below which `CommandGovernor` defers a dispatch
    /// of its own accord — i.e. where SELF-throttling begins.
    public let actionsFloor: Int
    /// The hub's last-read TOTAL holdings, or nil when no census row for the
    /// hub exists (or there is no hub on the mesh at all). Nil is "nobody has
    /// told us", never "zero" — and `RelayRun` treats it as a veto for the
    /// same reason.
    public let hubStock: Int?
    /// WHEN that reading was taken. Carried beside the figure rather than
    /// dropped, because a reading's AGE is one of the three things that can
    /// veto a print (`RelayRun.printStockIsShort`) and the other two are
    /// useless without it: an hour-old row showing 41,000 units against a
    /// 35,078 floor reads as comfortable headroom while the rail is in fact
    /// refusing every print. See `hubStockStanding(at:)`.
    public let hubStockFetchedAt: Date?
    /// `BrainCeiling.aggregateSpendFloor` — the reserve-floor rail the stock
    /// above is judged against.
    public let spendFloor: Int
    /// When the SERVER last answered 429, or nil if it never has this
    /// session. Kept as its own fact rather than inferred from
    /// `actionsRemaining`: being rate-limited is not the same event as pacing
    /// ourselves, and the design requires the two to read differently.
    public let rateLimitedAt: Date?

    public init(
        actionsRemaining: Int,
        actionsLimit: Int,
        actionsFloor: Int,
        hubStock: Int?,
        hubStockFetchedAt: Date?,
        spendFloor: Int,
        rateLimitedAt: Date?
    ) {
        self.actionsRemaining = actionsRemaining
        self.actionsLimit = actionsLimit
        self.actionsFloor = actionsFloor
        self.hubStock = hubStock
        self.hubStockFetchedAt = hubStockFetchedAt
        self.spendFloor = spendFloor
        self.rateLimitedAt = rateLimitedAt
    }

    /// Where the hub stock stands against the reserve-floor rail — ALL THREE
    /// of the rail's veto conditions, not just the two a bare figure can
    /// express.
    ///
    /// A deliberate mirror of `RelayRun.printStockIsShort`, in the same branch
    /// order, judged against the same `RelayRun.hubFreshness` bound, so the
    /// why-view cannot report headroom on a reading the rail is already
    /// refusing to believe. That agreement is enforced by test
    /// (`hubStockStandingAgreesWithTheRailItMirrors`) rather than by this
    /// comment: the two cannot share an implementation because they read
    /// different shapes (a `WorldSnapshot`'s footprint table vs. this report's
    /// single figure), so the next best thing is a test that fails the moment
    /// they disagree.
    ///
    /// Reports, never gates. `RelayRun` still owns the actual veto.
    public func hubStockStanding(at now: Date) -> HubStockStanding {
        // `hubStock` and `hubStockFetchedAt` are set together or not at all —
        // both come from the same optional `LocationFootprint` — but the
        // guard is written over both so a future caller that sets only one
        // degrades to "unread" (fails closed) rather than to "clear".
        guard let hubStock, let hubStockFetchedAt else { return .unread }
        let age = now.timeIntervalSince(hubStockFetchedAt)
        if age > RelayRun.hubFreshness { return .stale(age: age) }
        return hubStock < spendFloor ? .belowFloor : .clear
    }

    /// The reserve-floor rail's four outcomes, as an operator needs them
    /// distinguished. Three of them veto a print; only `.clear` permits one.
    public enum HubStockStanding: Equatable, Sendable {
        /// No census row for the hub at all — "nobody has told us", which is
        /// not the same claim as "the stock is fine".
        case unread
        /// A reading older than `RelayRun.hubFreshness`. The figure may look
        /// comfortable and still be worthless; `age` is what the operator
        /// actually needs told.
        case stale(age: TimeInterval)
        /// A fresh reading that sits below the reserve floor.
        case belowFloor
        /// A fresh reading with real headroom — the only state that permits a
        /// print.
        case clear
    }
}

/// A reclaim the tick actually took: the spare relay it is sourcing a grow
/// from, where that relay stands, and where it is going.
///
/// A GRAPH FACT rather than a device code, for the reason `Goal.rationale` is
/// one — "R9, at DEADEND, 7.1 ly from VEGA" is a statement an operator can hold
/// against the map, where `sourceRelayCode = R9` is one they must take on
/// trust. The same three fields `Brain.sourcing` already puts in the launch log
/// line, carried as data so the why-view can render the designations in
/// monospace without taking a sentence apart again (`BrainWhySpan`).
public struct BrainReclaim: Equatable, Sendable {
    /// The relay being reclaimed. A DEVICE code, not a designation — the
    /// monospace rule does not govern it.
    public let deviceCode: String
    /// The system it is standing in, and leaving.
    public let fromSystem: String
    /// The plant site it is going to — the grow's first hop.
    public let toSystem: String
    /// Straight-line light-years between the two.
    public let distanceLY: Double

    public init(deviceCode: String, fromSystem: String, toSystem: String, distanceLY: Double) {
        self.deviceCode = deviceCode
        self.fromSystem = fromSystem
        self.toSystem = toSystem
        self.distanceLY = distanceLY
    }
}

/// What prune saw this tick, and what the tick did about it — the prune half of
/// the why-view (`brain-robustness-bar` clause 8).
///
/// **Prune has no stall path, and this type has no way to express one.** A
/// useless relay left standing is an observation, never an escalation: "there
/// is a spare relay I have not reused yet" is not a problem an operator must
/// fix. Growth can halt and need a human; prune cannot, by construction.
///
/// **`declined` is carried through rather than flattened into an empty
/// `spare`.** `PrunePredicate` returns an all-pinned partition BOTH when it
/// cannot judge the world and when every relay is genuinely load-bearing, and
/// the two were byte-identical before `PruneDeclineReason` existed. "I can't
/// judge right now" and "nothing is spare" are different facts with different
/// fixes, so the feed keeps them apart and the why-view renders them apart.
public struct BrainPrune: Equatable, Sendable {
    /// The reclaim this tick took — present ONLY when the launch actually
    /// committed. A tick that chose a source and then deferred reports none:
    /// the relay is still standing where it was, and the report says what
    /// HAPPENED, exactly as `.dispatch` does.
    public let reclaimed: BrainReclaim?
    /// Spare relays a Relay Run is ALREADY flying to collect — spoken for, and
    /// so not available to anything else.
    ///
    /// **Split out of `spare` because a source relay stays deployed and
    /// `relaying` for the whole outbound leg of the run coming to fetch it.**
    /// `PrunePredicate` is stateless and keeps returning it as reclaimable for
    /// every one of the hundreds of ticks that flight takes — correctly, on the
    /// question prune was asked — so a surface that read `reclaimable` as
    /// "available" would describe prune's one action correctly for a single
    /// tick and misdescribe it for the rest of its lifetime. The claim is read
    /// off `Brain.inFlightSources`, the same authority the SOURCING side uses
    /// so it cannot offer one relay to two carriers.
    public let claimed: [ReclaimableRelay]
    /// Spare relays the tick left where they stand and nobody has claimed —
    /// genuinely available to the next grow. `reclaimed` and `claimed` are both
    /// excluded, so no relay is ever counted twice. Ordered by device code, as
    /// `PruneAnalysis.reclaimable` is.
    public let spare: [ReclaimableRelay]
    /// How many deployed relays the mesh needs — the count behind "nothing
    /// spare", which is meaningless without a scale.
    public let pinnedCount: Int
    /// Why prune refused to judge, when it did. See the type's own header.
    public let declined: PruneDeclineReason?

    public init(
        reclaimed: BrainReclaim?,
        claimed: [ReclaimableRelay] = [],
        spare: [ReclaimableRelay],
        pinnedCount: Int,
        declined: PruneDeclineReason?
    ) {
        self.reclaimed = reclaimed
        self.claimed = claimed
        self.spare = spare
        self.pinnedCount = pinnedCount
        self.declined = declined
    }
}

/// One brain tick, as reported to the operator: what it decided, the ranked
/// field it decided against, and the limits it decided under.
public struct BrainReport: Equatable, Sendable {
    /// What the tick did — already committed by the time this is published.
    public let decision: BrainDecision
    /// The whole grow field this tick ranked, best first.
    ///
    /// Carried here as well as inside `.dispatch(_, ranked:)` because the
    /// interesting ticks for an operator are the ones that DIDN'T launch:
    /// "deferred — carrier unavailable on confirm" is only legible next to
    /// the candidate it was deferred for. `.dispatch`'s own `ranked` is the
    /// decision-time contract Task 16 defined and stays untouched; on a
    /// dispatch tick the two are the same list by construction.
    public let ranked: [GrowCandidate]
    /// The print hub's location this tick, when there is one on the mesh.
    /// Present so the why-view can render the designations embedded in a gate
    /// like "no free carrier at SOL-3" in monospace — the projection matches
    /// against codes it was TOLD, never against a guess at what a code looks
    /// like.
    public let hubLocation: String?
    /// The rails, as read this tick.
    public let limits: BrainLimits
    /// What prune saw, or nil on a tick that never got as far as judging — no
    /// mesh yet, or a world read that failed. Nil is "nobody looked", never
    /// "the mesh is tidy", and the why-view renders it as silence rather than
    /// as reassurance.
    public let prune: BrainPrune?
    /// The tick's clock reading (`@Dependency(\.date)`, never `Date()`), so a
    /// "recent 429" window is judged against the same instant everything else
    /// on this report was.
    public let observedAt: Date

    public init(
        decision: BrainDecision,
        ranked: [GrowCandidate],
        hubLocation: String?,
        limits: BrainLimits,
        prune: BrainPrune? = nil,
        observedAt: Date
    ) {
        self.decision = decision
        self.ranked = ranked
        self.hubLocation = hubLocation
        self.limits = limits
        self.prune = prune
        self.observedAt = observedAt
    }
}

extension SharedReaderKey where Self == InMemoryKey<BrainReport?> {
    /// The brain's live report, published by `tickBrain()` and read by the
    /// Directives surface. In-memory only: no table, no migration, and
    /// nothing survives a relaunch — the next tick, five seconds later,
    /// replaces it wholesale.
    public static var brainReport: Self { .inMemory("brainReport") }
}
