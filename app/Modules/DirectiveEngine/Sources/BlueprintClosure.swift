//
//  BlueprintClosure.swift
//  Replicould — DirectiveEngine
//
//  What a set of devices really costs: raw material rolled up through the
//  blueprint components each one consumes, and the prints that build them.
//

import Foundation
import GameModels

public enum BlueprintClosure {
    /// One print in a build order. `depth` is 0 for a requested device and rises
    /// by one per component level, so a higher depth must print first.
    public struct Job: Equatable, Sendable {
        public let deviceType: String
        public let quantity: Int
        public let depth: Int

        public init(deviceType: String, quantity: Int, depth: Int) {
            self.deviceType = deviceType
            self.quantity = quantity
            self.depth = depth
        }
    }

    /// A device set costed through its whole component tree. `resources` is a
    /// LOWER BOUND whenever `unprintable` is non-empty — callers must branch on
    /// the set, never on the number.
    public struct Expansion: Equatable, Sendable {
        public let resources: ResourceCost
        public let jobs: [Job]
        public let printSeconds: Int
        public let unprintable: Set<String>

        public init(
            resources: ResourceCost, jobs: [Job], printSeconds: Int, unprintable: Set<String>
        ) {
            self.resources = resources
            self.jobs = jobs
            self.printSeconds = printSeconds
            self.unprintable = unprintable
        }
    }

    /// Expand `wanted` through `components`, costing each node from `bills`. A
    /// device with no bill, and a device already on the current path, are both
    /// recorded in `unprintable` and their subtrees abandoned.
    public static func expand(
        _ wanted: [String: Int],
        bills: [String: ResourceCost],
        components: [String: [String: Int]],
        printTimes: [String: Int] = [:]
    ) -> Expansion {
        var resources = ResourceCost()
        var quantities: [String: Int] = [:]
        var depths: [String: Int] = [:]
        var unprintable: Set<String> = []

        func visit(_ type: String, _ quantity: Int, _ depth: Int, _ path: Set<String>) {
            guard !path.contains(type) else { unprintable.insert(type); return }
            guard let bill = bills[type] else { unprintable.insert(type); return }
            resources.add(bill.scaled(by: quantity))
            quantities[type, default: 0] += quantity
            depths[type] = max(depths[type] ?? 0, depth)
            let onward = path.union([type])
            for (child, count) in components[type] ?? [:] {
                visit(child, quantity * count, depth + 1, onward)
            }
        }

        for (type, quantity) in wanted where quantity > 0 {
            visit(type, quantity, 0, [])
        }

        let unsortedJobs: [Job] = quantities.map { type, quantity in
            Job(deviceType: type, quantity: quantity, depth: depths[type] ?? 0)
        }
        let jobs = unsortedJobs.sorted { (lhs: Job, rhs: Job) -> Bool in
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            return lhs.deviceType < rhs.deviceType
        }
        let seconds = jobs.reduce(0) { $0 + (printTimes[$1.deviceType] ?? 0) * $1.quantity }
        return Expansion(
            resources: resources, jobs: jobs, printSeconds: seconds, unprintable: unprintable
        )
    }
}
