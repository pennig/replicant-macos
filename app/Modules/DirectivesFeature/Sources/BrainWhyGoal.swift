//
//  BrainWhyGoal.swift
//  Replicould — Directives feature
//
//  Salvage and haul each get their own line in the why-view, in `BrainWhySurvey`'s
//  voice over their own fleets. Own file per the list-row-preview-crash rule.
//

/// One line of "what a liveness goal is doing" in the why-view.
public struct BrainWhyGoal: Equatable, Sendable, Identifiable {
    public enum Goal: String, Sendable, CaseIterable {
        case salvage
        case haul

        /// The label the row reads under.
        public var title: String {
            switch self {
            case .salvage: "Salvage"
            case .haul: "Haul"
            }
        }
    }

    public enum Kind: String, Sendable, CaseIterable {
        case running
        case halted
        case paused
        case ready
        case idle
    }

    public let goal: Goal
    public let kind: Kind
    /// The fact, with any designation tagged for the mono token.
    public let spans: [BrainWhySpan]

    public var id: String { "\(goal.rawValue).\(kind.rawValue)" }
    public var text: String { spans.text }

    public init(goal: Goal, kind: Kind, spans: [BrainWhySpan]) {
        self.goal = goal
        self.kind = kind
        self.spans = spans
    }
}
