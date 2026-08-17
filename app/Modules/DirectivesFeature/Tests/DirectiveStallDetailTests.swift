//
//  DirectiveStallDetailTests.swift
//  Replicould — Directives feature
//
//  Pure transform tests — no database, no store, just the column read and its legacy fallback.
//

import Foundation
import GameModels
import Testing
@testable import DirectivesFeature

private func entry(
    _ id: String, kind: DirectiveLogKind = .stalled, summary: String, at seconds: TimeInterval,
    detail: String? = nil
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: kind,
        summary: summary, step: nil, operationID: nil, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: seconds), detail: detail
    )
}

@Suite("Directive stall detail")
struct DirectiveStallDetailTests {
    /// The `detail` column is the record. The summary here carries a different
    /// suffix, so a reader still stripping the prefix answers with that instead.
    @Test func readsTheDetailColumnNotTheSummary() {
        let reason = DirectiveAttentionReason.salvageBodyNotDepleted
        let entries = [entry(
            "L1", summary: "\(reason.rawValue): MEREDIANA-9", at: 10, detail: "MEREDIANA-3"
        )]
        #expect(DirectiveStallDetail.detail(for: reason, in: entries) == "MEREDIANA-3")
    }

    /// A row written before the column existed carries the detail only in the
    /// summary, so the fallback is the only thing that can answer. Delete it
    /// and this reads nil. Stage 2 deletes both.
    @Test func fallsBackToTheSummaryForALegacyRow() {
        let reason = DirectiveAttentionReason.salvageBodyNotDepleted
        let entries = [entry("L1", summary: "\(reason.rawValue): MEREDIANA-3", at: 10)]
        #expect(DirectiveStallDetail.detail(for: reason, in: entries) == "MEREDIANA-3")
    }

    /// A summary whose prefix names a DIFFERENT reason is some earlier stall's
    /// record, not this one's — never show it under the current headline.
    @Test func rejectsASummaryNamingAnotherReason() {
        let entries = [entry(
            "L1",
            summary: "\(DirectiveAttentionReason.commandRejected.rawValue): device offline",
            at: 10, detail: "device offline"
        )]
        #expect(DirectiveStallDetail.detail(for: .salvageBodyNotDepleted, in: entries) == nil)
    }

    /// A detail-less stall writes the bare rawValue — no colon, no suffix.
    @Test func rejectsADetaillessSummary() {
        let reason = DirectiveAttentionReason.salvageBodyNotDepleted
        let entries = [entry("L1", summary: reason.rawValue, at: 10)]
        #expect(DirectiveStallDetail.detail(for: reason, in: entries) == nil)
    }

    /// Only the NEWEST `.stalled` entry speaks for the row's current reason,
    /// whatever order the entries arrive in.
    @Test func readsTheNewestStalledEntry() {
        let reason = DirectiveAttentionReason.salvageBodyNotDepleted
        let entries = [
            entry("L1", summary: "\(reason.rawValue): MEREDIANA-2", at: 10, detail: "MEREDIANA-2"),
            entry("L2", summary: "\(reason.rawValue): MEREDIANA-3", at: 30, detail: "MEREDIANA-3"),
            entry("L3", kind: .stepStarted, summary: "Step: verifying", at: 40),
        ]
        #expect(DirectiveStallDetail.detail(for: reason, in: entries) == "MEREDIANA-3")
    }

    /// No `.stalled` entry at all — a freshly-selected row, or a pruned log.
    @Test func returnsNilWithNoStalledEntry() {
        let entries = [entry("L1", kind: .stepStarted, summary: "Step: verifying", at: 10)]
        #expect(DirectiveStallDetail.detail(for: .salvageBodyNotDepleted, in: entries) == nil)
    }
}
