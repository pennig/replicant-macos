//
//  BrainWhyTheatreGroup.swift
//  Replicould — Directives feature
//
//  The why-view's per-theatre section: one operational theatre's standing
//  activities, or a claimed theatre's shortfalls in their place — no goal
//  runs at a theatre that is not yet operational.
//

/// One theatre's slice of the why-view.
public struct BrainWhyTheatreGroup: Equatable, Identifiable, Sendable {
    /// One activity line — grow, survey, or a liveness goal.
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let spans: [BrainWhySpan]
        public let kind: BrainWhyGoal.Kind

        public var text: String { spans.text }

        public init(id: String, label: String, spans: [BrainWhySpan], kind: BrainWhyGoal.Kind) {
            self.id = id
            self.label = label
            self.spans = spans
            self.kind = kind
        }
    }

    public let depot: String
    /// Empty for a `.claimed` theatre — see `shortfallLines`.
    public let goalLines: [Line]
    /// What the theatre lacks, in the operator's own words. Empty once
    /// `.operational`.
    public let shortfallLines: [String]

    public var id: String { depot }

    public init(depot: String, goalLines: [Line], shortfallLines: [String]) {
        self.depot = depot
        self.goalLines = goalLines
        self.shortfallLines = shortfallLines
    }
}
