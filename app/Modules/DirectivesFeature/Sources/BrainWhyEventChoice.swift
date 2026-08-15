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
        /// Whether this option's tree needs a blueprint the account lacks. No
        /// amount of printing or waiting reaches it.
        public let needsAMissingBlueprint: Bool
        public var id: String { name }

        public init(
            name: String,
            fact: String,
            stock: String,
            holdsEveryDevice: Bool,
            exceedsOneFreighterLoad: Bool,
            needsAMissingBlueprint: Bool = false
        ) {
            self.name = name
            self.fact = fact
            self.stock = stock
            self.holdsEveryDevice = holdsEveryDevice
            self.exceedsOneFreighterLoad = exceedsOneFreighterLoad
            self.needsAMissingBlueprint = needsAMissingBlueprint
        }
    }

    /// The event's own code. A designation: always mono.
    public let designation: String
    /// Where it stands. A designation: always mono.
    public let location: String
    public let tier: Int
    public let options: [Option]
    /// Whether NO option can be built — a report, not a decision. Never derive
    /// it from an option's missing blueprints: a cold catalogue populates those
    /// on an event that is merely awaiting a pick.
    public let isBlocked: Bool
    public var id: String { designation }

    public init(
        designation: String, location: String, tier: Int, options: [Option],
        isBlocked: Bool = false
    ) {
        self.designation = designation
        self.location = location
        self.tier = tier
        self.options = options
        self.isBlocked = isBlocked
    }

    /// Projects one `BrainEventChoice` off the tick's report.
    public init(_ choice: BrainEventChoice) {
        self.init(
            designation: choice.designation,
            location: choice.location,
            tier: choice.tier,
            options: choice.options.map { Option($0, blocked: choice.isBlocked) },
            isBlocked: choice.isBlocked
        )
    }
}

extension BrainWhyEventChoice.Option {
    /// `blocked` is the event's own verdict, and the ONLY gate on the missing
    /// blueprint wording: a cold catalogue leaves `unprintable` populated on an
    /// option that is merely awaiting a pick.
    init(_ option: BrainEventChoice.Option, blocked: Bool) {
        self.init(
            name: option.name,
            fact: Self.fact(
                build: option.deviceUnits, ship: option.resourceUnits,
                required: option.requiredDevices
            ),
            stock: Self.stock(
                required: option.requiredDevices, missing: option.missingDevices,
                unprintable: blocked ? option.unprintable : []
            ),
            holdsEveryDevice: option.missingDevices.isEmpty,
            exceedsOneFreighterLoad: option.exceedsOneFreighterLoad,
            needsAMissingBlueprint: blocked && !option.unprintable.isEmpty
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

    /// The missing blueprints lead: a shortfall the fleet could print is a
    /// different problem from one no print reaches.
    private static func stock(
        required: [String], missing: [String], unprintable: [String]
    ) -> String {
        if !unprintable.isEmpty {
            return "no blueprint for \(unprintable.map(label).joined(separator: ", "))"
        }
        guard !required.isEmpty else { return "no devices needed" }
        guard !missing.isEmpty else { return "every device in stock" }
        return "needs \(missing.map(label).joined(separator: ", "))"
    }

    /// The same formatter the stall panel's detail uses, so one device type
    /// cannot read two ways across two surfaces.
    private static func label(_ deviceType: String) -> String {
        BlueprintPresentation.displayName(deviceType)
    }
}
