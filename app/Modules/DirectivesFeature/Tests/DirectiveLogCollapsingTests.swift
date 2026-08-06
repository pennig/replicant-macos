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

    /// A period-2 cycle (not just a repeated single step) collapses to one
    /// row carrying the repetition count.
    @Test func collapsesAPeriodTwoCycle() {
        let entries = [
            entry("L1", step: "ping", at: 40),
            entry("L2", step: "pong", at: 30),
            entry("L3", step: "ping", at: 20),
            entry("L4", step: "pong", at: 10),
        ]
        let rows = DirectiveLogCollapsing.collapse(entries)
        #expect(rows.map(\.id) == ["L1"])
        #expect(rows.first?.count == 2)
    }

    /// A cycle that changes shape partway through renders as two collapsed
    /// rows, never merged into one longer-period read of the whole window.
    @Test func cycleShapeChangePartwayStaysSeparate() {
        let entries = [
            entry("A1", step: "alpha", at: 60), entry("B1", step: "beta", at: 50), entry("C1", step: "gamma", at: 40),
            entry("A2", step: "alpha", at: 30), entry("B2", step: "beta", at: 20), entry("C2", step: "gamma", at: 10),
            entry("D1", step: "delta", at: 0), entry("E1", step: "epsilon", at: -10), entry("F1", step: "zeta", at: -20),
            entry("D2", step: "delta", at: -30), entry("E2", step: "epsilon", at: -40), entry("F2", step: "zeta", at: -50),
        ]
        let rows = DirectiveLogCollapsing.collapse(entries)
        #expect(rows.map(\.id) == ["A1", "D1"])
        #expect(rows.map(\.count) == [2, 2])
    }

    /// The real fixture behind this feature: a Haul Run's newest 24
    /// `.stepStarted` entries, a period-3 cycle interrupted once by a
    /// repoint (`confirming`/`dispatching` swapped in for a beat). The
    /// repoint must stand apart, never absorbed into either cycle run.
    @Test func realHaulRunCycleWithARepointCollapses() {
        let steps = [
            "assigning", "surveying", "hauling",
            "assigning", "surveying", "hauling",
            "assigning", "confirming", "dispatching",
            "assigning", "surveying", "hauling",
            "assigning", "surveying", "hauling",
            "assigning", "surveying", "hauling",
            "assigning", "surveying", "hauling",
            "assigning", "surveying", "hauling",
        ]
        let entries = steps.enumerated().map { index, step in
            entry("L\(index)", step: step, at: TimeInterval(steps.count - index))
        }
        let rows = DirectiveLogCollapsing.collapse(entries)
        #expect(rows.map(\.count) == [2, 1, 1, 1, 5])
        #expect(rows[1].unit.first?.step == "assigning")
        #expect(rows[2].unit.first?.step == "confirming")
        #expect(rows[3].unit.first?.step == "dispatching")
    }
}
