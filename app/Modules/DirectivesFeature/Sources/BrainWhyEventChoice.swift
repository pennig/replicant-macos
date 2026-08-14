//
//  BrainWhyEventChoice.swift
//  Replicould — Directives feature
//
//  One event the brain cannot rank until an operator picks how to satisfy it.
//  A prompt, never a fault: the brain is working normally. Its view is
//  `BrainWhyEventChoiceRowView`, split off per the list-row-preview-crash rule.
//

import DirectiveEngine
import GameModels

/// A pending fulfilment decision, as the operator needs it read: which event,
/// where, and what each option would cost against what the fleet holds.
public struct BrainWhyEventChoice: Equatable, Identifiable, Sendable {
    /// One option, priced. `fact` and `stock` are designation-free, so the
    /// view renders both wholly in the prose token.
    public struct Option: Equatable, Identifiable, Sendable {
        public let name: String
        /// The bill — "700 units to build · 150 to ship".
        public let fact: String
        /// What the fleet is short, or that it is short of nothing.
        public let stock: String
        /// Whether `stock` reads as held. Carried beside the sentence so the
        /// row can differ in glyph as well as wording.
        public let holdsEveryDevice: Bool
        public let exceedsOneFreighterLoad: Bool
        public var id: String { name }

        public init(
            name: String,
            fact: String,
            stock: String,
            holdsEveryDevice: Bool,
            exceedsOneFreighterLoad: Bool
        ) {
            self.name = name
            self.fact = fact
            self.stock = stock
            self.holdsEveryDevice = holdsEveryDevice
            self.exceedsOneFreighterLoad = exceedsOneFreighterLoad
        }
    }

    /// The event's own code. A designation: always mono.
    public let designation: String
    /// Where it stands. A designation: always mono.
    public let location: String
    public let tier: Int
    public let options: [Option]
    public var id: String { designation }

    public init(designation: String, location: String, tier: Int, options: [Option]) {
        self.designation = designation
        self.location = location
        self.tier = tier
        self.options = options
    }

    /// Projects one `BrainEventChoice` off the tick's report.
    public init(_ choice: BrainEventChoice) {
        self.init(
            designation: choice.designation,
            location: choice.location,
            tier: choice.tier,
            options: choice.options.map(Option.init)
        )
    }
}

extension BrainWhyEventChoice.Option {
    init(_ option: BrainEventChoice.Option) {
        self.init(
            name: option.name,
            fact: Self.fact(
                build: option.deviceUnits, ship: option.resourceUnits,
                required: option.requiredDevices
            ),
            stock: Self.stock(required: option.requiredDevices, missing: option.missingDevices),
            holdsEveryDevice: option.missingDevices.isEmpty,
            exceedsOneFreighterLoad: option.exceedsOneFreighterLoad
        )
    }

    /// An option calling for devices the blueprint catalogue cannot price says
    /// so. Reporting it as a zero would contradict `stock` in the same line.
    private static func fact(build: Int, ship: Int, required: [String]) -> String {
        var clauses: [String] = []
        if build > 0 {
            clauses.append("\(build.formatted()) units to build")
        } else if !required.isEmpty {
            clauses.append("build cost unpriced")
        }
        if ship > 0 {
            clauses.append(clauses.isEmpty ? "\(ship.formatted()) units to ship" : "\(ship.formatted()) to ship")
        }
        return clauses.isEmpty ? "nothing to deliver" : clauses.joined(separator: " · ")
    }

    private static func stock(required: [String], missing: [String]) -> String {
        guard !required.isEmpty else { return "no devices needed" }
        guard !missing.isEmpty else { return "every device in stock" }
        return "needs \(missing.map(label).joined(separator: ", "))"
    }

    private static func label(_ deviceType: String) -> String {
        deviceType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
