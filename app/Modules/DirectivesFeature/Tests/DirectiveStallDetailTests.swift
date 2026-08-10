//
//  DirectiveStallDetailTests.swift
//  Replicould — Directives feature
//
//  Pure transform tests — no database, no store, just the summary parsing.
//

import Foundation
import GameModels
import Testing
@testable import DirectivesFeature

private func entry(
    _ id: String, kind: DirectiveLogKind = .stalled, summary: String, at seconds: TimeInterval
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: kind,
        summary: summary, step: nil, operationID: nil, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: seconds)
    )
}

@Suite("Directive stall detail")
struct DirectiveStallDetailTests {
    /// Round-trips the executor's summary format, `"<reason.rawValue>: <detail>"`.
    @Test func recoversTheDetailTheExecutorWrote() {
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
            at: 10
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
            entry("L1", summary: "\(reason.rawValue): MEREDIANA-2", at: 10),
            entry("L2", summary: "\(reason.rawValue): MEREDIANA-3", at: 30),
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
