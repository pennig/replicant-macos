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
        spendFloor: Int,
        rateLimitedAt: Date?
    ) {
        self.actionsRemaining = actionsRemaining
        self.actionsLimit = actionsLimit
        self.actionsFloor = actionsFloor
        self.hubStock = hubStock
        self.spendFloor = spendFloor
        self.rateLimitedAt = rateLimitedAt
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
    /// The tick's clock reading (`@Dependency(\.date)`, never `Date()`), so a
    /// "recent 429" window is judged against the same instant everything else
    /// on this report was.
    public let observedAt: Date

    public init(
        decision: BrainDecision,
        ranked: [GrowCandidate],
        hubLocation: String?,
        limits: BrainLimits,
        observedAt: Date
    ) {
        self.decision = decision
        self.ranked = ranked
        self.hubLocation = hubLocation
        self.limits = limits
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
