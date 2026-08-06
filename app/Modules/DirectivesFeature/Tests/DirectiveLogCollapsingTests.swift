//
//  DirectiveLogCollapsingTests.swift
//  Replicould — Directives feature
//
//  Pure transform tests — no database, no store, just the collapsing rule.
//

import Foundation
import GameModels
import Testing
@testable import DirectivesFeature

private func entry(
    _ id: String, step: String? = nil, kind: DirectiveLogKind = .stepStarted, at seconds: TimeInterval
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: kind,
        summary: "entry \(id)", step: step, operationID: nil, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: seconds)
    )
}

@Suite("Directive log collapsing")
struct DirectiveLogCollapsingTests {
    /// A run of identical consecutive steps collapses to one row carrying
    /// the repeat count.
    @Test func collapsesAConsecutiveRun() {
        let entries = [
            entry("L1", step: "hauling", at: 30),
            entry("L2", step: "hauling", at: 20),
            entry("L3", step: "hauling", at: 10),
        ]
        let rows = DirectiveLogCollapsing.collapse(entries)
        #expect(rows.map(\.id) == ["L1"])
        #expect(rows.first?.count == 3)
    }

    /// Two runs of the same step separated by another entry stay separate —
    /// that separation is the whole point of collapsing only consecutively.
    @Test func separatedRunsStaySeparate() {
        let entries = [
            entry("L1", step: "hauling", at: 30),
            entry("L2", kind: .commandDispatched, at: 20),
            entry("L3", step: "hauling", at: 10),
        ]
        let rows = DirectiveLogCollapsing.collapse(entries)
        #expect(rows.map(\.id) == ["L1", "L2", "L3"])
        #expect(rows.allSatisfy { $0.count == 1 })
    }

    /// A Survey-Run-shaped sequence of distinct steps, each appearing once,
    /// collapses to nothing — it renders exactly as it arrived.
    @Test func distinctStepsRenderUnchanged() {
        let entries = [
            entry("L1", step: "preflight", at: 30),
            entry("L2", step: "surveying", at: 20),
            entry("L3", step: "returning", at: 10),
        ]
        let rows = DirectiveLogCollapsing.collapse(entries)
        #expect(rows.map(\.id) == ["L1", "L2", "L3"])
        #expect(rows.allSatisfy { $0.count == 1 })
    }

    @Test func emptyInputIsHandled() {
        #expect(DirectiveLogCollapsing.collapse([]).isEmpty)
    }
}
