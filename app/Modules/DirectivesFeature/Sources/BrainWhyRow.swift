//
//  BrainWhyRow.swift
//  Replicould — Directives feature
//
//  One candidate the brain's why-view is showing the operator, expressed as
//  a graph fact rather than a score — mirrors `Goal`'s own `target`/
//  `rationale` pair (`DirectiveEngine/BrainGoal.swift`). Kept in its own file
//  per the list-row-preview-crash rule: a row struct beside a `#Preview`
//  crashes the Xcode 26 preview JIT.
//
//  Deliberately minimal: `.dispatch` doesn't exist on `BrainDecision` yet
//  (Task 12), so nothing populates `candidates` this build. Task 19 drives
//  this type's real shape against `GrowCandidate` — don't grow it ahead of
//  that need.
//

/// A single candidate the brain considered, as the operator would read it on
/// the map: the system it targets, and why in graph-fact terms.
public struct BrainWhyRow: Equatable, Identifiable, Sendable {
    public var id: String { target }

    /// The candidate's target system/relay designation.
    public let target: String
    /// A graph fact, never a scalar — see `Goal.rationale`.
    public let rationale: String

    public init(target: String, rationale: String) {
        self.target = target
        self.rationale = rationale
    }
}
