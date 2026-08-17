//
//  MissionLogBudgetTests.swift
//  Replicould — DirectiveEngine
//
//  Typed-column fixtures whose summaries name a DIFFERENT verb and device, so a reader that split prose fails.
//

import Foundation
import GameModels
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)
private let dispatchStep = "arming"
private let confirmStep = "confirmingArm"

private func stepEntry(_ step: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "S-\(step)-\(occurredAt.timeIntervalSince1970)", directiveID: "D1", deviceCode: nil,
        kind: .stepStarted, summary: "Step: \(step)", step: step, operationID: nil,
        eventID: nil, occurredAt: occurredAt
    )
}

/// A dispatch entry as the executor writes one today: typed columns, plus a
/// summary that DELIBERATELY names a different verb and device.
private func typedDispatch(
    _ commandKind: OperationKind, to targetDeviceCode: String,
    summarising decoy: String, at occurredAt: Date
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "C-\(commandKind.rawValue)-\(occurredAt.timeIntervalSince1970)", directiveID: "D1",
        deviceCode: nil, kind: .commandDispatched, summary: decoy, step: confirmStep,
        operationID: nil, eventID: nil, occurredAt: occurredAt,
        commandKind: commandKind.rawValue, targetDeviceCode: targetDeviceCode
    )
}

/// A row written before the migration: no columns, only the prose.
private func legacyDispatch(summary: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L-\(occurredAt.timeIntervalSince1970)", directiveID: "D1", deviceCode: nil,
        kind: .commandDispatched, summary: summary, step: confirmStep, operationID: nil,
        eventID: nil, occurredAt: occurredAt
    )
}

private func world(_ log: [DirectiveLogEntry]) -> WorldSnapshot {
    WorldSnapshot(devices: [:], openOperations: [:], log: log, now: now)
}

private func lastDispatch(_ log: [DirectiveLogEntry]) -> MissionLogBudget.LastDispatch {
    MissionLogBudget.lastDispatch(world(log), dispatch: dispatchStep, confirm: confirmStep)
}

@Suite("Mission log budget — typed command columns")
struct MissionLogBudgetTests {
    /// The columns are the record. The summary here says `travel`/`V9`, so a
    /// reader still splitting prose answers with those instead.
    @Test func lastDispatchReadsTheColumnsNotTheSummary() {
        let log = [
            stepEntry(dispatchStep, at: now.addingTimeInterval(-30)),
            typedDispatch(
                .attach, to: "M07", summarising: "Dispatched travel to V9 — SOL",
                at: now.addingTimeInterval(-20)
            ),
        ]
        #expect(lastDispatch(log) == .dispatched(kind: "attach", deviceCode: "M07"))
    }

    /// A row written before the migration carries the fact only in the prose,
    /// so the fallback is the only thing that can answer. Delete it and this
    /// reads `.nothingSent`. Stage 2 deletes both.
    @Test func lastDispatchFallsBackToTheSummaryForALegacyRow() {
        let log = [
            stepEntry(dispatchStep, at: now.addingTimeInterval(-30)),
            legacyDispatch(summary: "Dispatched travel to V9 — SOL", at: now.addingTimeInterval(-20)),
        ]
        #expect(lastDispatch(log) == .dispatched(kind: "travel", deviceCode: "V9"))
    }

    /// A legacy row whose prose does not parse either names no order at all —
    /// the dispatch step is then the only step that can make progress.
    @Test func anUnparseableLegacyRowNamesNoOrder() {
        let log = [
            stepEntry(dispatchStep, at: now.addingTimeInterval(-30)),
            legacyDispatch(summary: "sent something somewhere", at: now.addingTimeInterval(-20)),
        ]
        #expect(lastDispatch(log) == .nothingSent)
    }

    /// A resolved stall re-enters the loop holding no record of its own order.
    @Test func aResolvedStallNamesNoOrder() {
        let log = [
            typedDispatch(
                .attach, to: "M07", summarising: "Dispatched attach to M07",
                at: now.addingTimeInterval(-30)
            ),
            DirectiveLogEntry(
                id: "R1", directiveID: "D1", deviceCode: nil, kind: .resolved,
                summary: "resolved", step: confirmStep, operationID: nil, eventID: nil,
                occurredAt: now.addingTimeInterval(-20)
            ),
        ]
        #expect(lastDispatch(log) == .nothingSent)
    }

    /// Counting by column: two `travel` rounds whose summaries say `attach`,
    /// and one `attach` round whose summary says `travel`. Prose counts one.
    @Test func dispatchRoundsCountsTheColumnNotTheSummary() {
        let log = [
            stepEntry(dispatchStep, at: now.addingTimeInterval(-60)),
            typedDispatch(
                .travel, to: "V1", summarising: "Dispatched attach to V1", at: now.addingTimeInterval(-50)
            ),
            typedDispatch(
                .travel, to: "V2", summarising: "Dispatched attach to V2", at: now.addingTimeInterval(-40)
            ),
            typedDispatch(
                .attach, to: "V3", summarising: "Dispatched travel to V3", at: now.addingTimeInterval(-30)
            ),
        ]
        let counted = MissionLogBudget.dispatchRounds(
            world(log), dispatch: dispatchStep, confirm: confirmStep, kind: .travel
        )
        #expect(counted == 2)
    }

    /// Legacy rows carry the verb only in the prose, so the fallback is the
    /// only thing that can count them. Delete it and this reads 0. Stage 2
    /// deletes both.
    @Test func dispatchRoundsCountsLegacyRowsFromTheSummary() {
        let log = [
            stepEntry(dispatchStep, at: now.addingTimeInterval(-60)),
            legacyDispatch(summary: "Dispatched travel to V1 — SOL", at: now.addingTimeInterval(-50)),
            legacyDispatch(summary: "Dispatched travel to V2 — SOL", at: now.addingTimeInterval(-40)),
            legacyDispatch(summary: "Dispatched attach to V3", at: now.addingTimeInterval(-30)),
        ]
        let counted = MissionLogBudget.dispatchRounds(
            world(log), dispatch: dispatchStep, confirm: confirmStep, kind: .travel
        )
        #expect(counted == 2)
    }

    /// The count is the CURRENT run's: an entry from before the loop was
    /// entered belongs to an earlier visit and cannot spend this visit's budget.
    @Test func dispatchRoundsStopsAtAnUnrelatedStep() {
        let log = [
            typedDispatch(
                .travel, to: "V1", summarising: "Dispatched travel to V1", at: now.addingTimeInterval(-60)
            ),
            stepEntry("travelling", at: now.addingTimeInterval(-50)),
            stepEntry(dispatchStep, at: now.addingTimeInterval(-40)),
            typedDispatch(
                .travel, to: "V2", summarising: "Dispatched travel to V2", at: now.addingTimeInterval(-30)
            ),
        ]
        let counted = MissionLogBudget.dispatchRounds(
            world(log), dispatch: dispatchStep, confirm: confirmStep, kind: .travel
        )
        #expect(counted == 1)
    }
}
