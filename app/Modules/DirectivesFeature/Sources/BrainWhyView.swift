//
//  BrainWhyView.swift
//  Replicould — Directives feature
//
//  The brain's legibility surface (brain-robustness-bar clause 8): a derived
//  view model projecting a `BrainDecision` into graph facts an operator can
//  verify against the map, plus a minimal read-only SwiftUI card rendering
//  it. No table backs this — like `WorldView`, it's recomputed from what the
//  engine already persisted, never written itself.
//
//  Not wired into `DirectivesListView` this task: there is currently no path
//  by which a live `BrainDecision` reaches the UI (`tickBrain()` computes
//  one and discards it, by design for this phase — see `DirectiveEngine.swift`).
//  Wiring a static decision in now would mean rendering a value the engine
//  isn't actually reporting, which is the fake-data-source trap this surface
//  exists to avoid. Task 19 (the live ranked-candidate feed) wires this view
//  into the Directives surface together with its actual data source.
//
//  `BrainWhy` is deliberately top-level here rather than nested in
//  `BrainWhyView` — logic nested on a SwiftUI `View` traps `swift test`
//  (realizing the View's runtime metadata outside a GUI context), so the
//  test file exercises this type directly with no SwiftUI in the loop.
//

import DirectiveEngine
import SwiftUI
import UI

/// A `BrainDecision`, projected into what an operator needs to read at a
/// glance: the current goal gate, any candidates under consideration, and
/// what's constraining spend — all as text, never a number to interpret.
public struct BrainWhy: Equatable, Sendable {
    /// The decision's headline, e.g. "idle — no grow or prune work" or
    /// "stalled — Relay didn't come up".
    public var topGoalGate: String
    /// Ranked candidates under consideration. Always empty until `.dispatch`
    /// exists on `BrainDecision` (Task 12) and a later task populates this.
    public var candidates: [BrainWhyRow]
    /// Spend-ceiling facts constraining the brain's choices, e.g. an idle
    /// relay cap. Always empty until a task that produces limit pressure.
    public var limitPressure: [String]
    /// Distinguishes idle-calm from a stall (robustness bar clause 6): a
    /// brain with nothing to do is surfaced but calm; a stalled one is
    /// surfaced AND escalated. The view must not let these look alike.
    public var isEscalated: Bool

    public init(topGoalGate: String, candidates: [BrainWhyRow], limitPressure: [String], isEscalated: Bool) {
        self.topGoalGate = topGoalGate
        self.candidates = candidates
        self.limitPressure = limitPressure
        self.isEscalated = isEscalated
    }

    /// Projects the brain's tick result into the why-view's shape. `view` is
    /// unused while only `.idle`/`.stall` exist — later phases (`.dispatch`)
    /// read it to explain a candidate's rationale against the galaxy state.
    ///
    /// Exhaustive over `BrainDecision`'s current two cases, no `default:` —
    /// adding `.dispatch` must force this switch open again.
    public static func from(decision: BrainDecision, view: WorldView?) -> BrainWhy {
        switch decision {
        case let .idle(reason):
            BrainWhy(topGoalGate: "idle — \(reason)", candidates: [], limitPressure: [], isEscalated: false)
        case let .stall(reason):
            BrainWhy(topGoalGate: "stalled — \(reason.displayName)", candidates: [], limitPressure: [], isEscalated: true)
        }
    }
}

/// A read-only card rendering a `BrainWhy`. Actions (launch/retire) already
/// ride the `DirectiveLogEntry` timeline elsewhere in this feature, so this
/// surface never dispatches anything — it only explains.
public struct BrainWhyView: View {
    let why: BrainWhy

    public init(why: BrainWhy) {
        self.why = why
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: why.isEscalated ? "exclamationmark.triangle.fill" : "brain.head.profile")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(why.isEscalated ? .rcWarning : .rcTextSecondary)
                Text(why.topGoalGate)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                Spacer(minLength: 0)
            }

            if !why.limitPressure.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(why.limitPressure, id: \.self) { pressure in
                        Text(pressure)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
            }

            if !why.candidates.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(why.candidates) { candidate in
                        HStack(spacing: Space.xs) {
                            Text(candidate.target)
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextPrimary)
                            Text(candidate.rationale)
                                .font(.rcCaption)
                                .foregroundStyle(.rcTextSecondary)
                        }
                    }
                }
            }
        }
        .padding(Space.m)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
        )
    }
}
