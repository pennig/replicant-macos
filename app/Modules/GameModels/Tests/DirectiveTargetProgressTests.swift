//
//  DirectiveTargetProgressTests.swift
//  Replicould — GameModels
//
//  `targetIndex` is a CURSOR, not a completion count, and the Targets list in
//  `DirectiveDetailView` used to read it as one.
//
//  Found live on 2026-08-04: a Relay Run to NERVIU showed `completed`, the
//  relay was genuinely `relaying` at `NERVIU-6-L4` and the system was meshed —
//  and the detail view drew an empty circle beside the target. `RelayRun` is
//  single-target and never advances the cursor, so it finishes with
//  `targetIndex == 0` and the old `index < targetIndex` test evaluated `0 < 0`.
//
//  Advancing the cursor at the end would NOT have been the fix: `settle` and
//  `returnHome` both read `currentTarget`, which is `targets[targetIndex]` and
//  goes nil the moment the cursor passes the end.
//

import Foundation
import Testing
@testable import GameModels

private func run(
    kind: DirectiveKind,
    status: DirectiveStatus,
    targets: [String],
    targetIndex: Int
) -> Directive {
    Directive(
        id: "D1", kind: kind, status: status, deviceCode: "V1",
        targets: targets, targetIndex: targetIndex, step: "settling",
        stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: true,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Directive — target delivery")
struct DirectiveTargetProgressTests {

    /// **The live regression, exactly as it stood.** A completed single-target
    /// Relay Run whose cursor never moved must read as delivered.
    @Test func aCompletedSingleTargetRunReadsAsDelivered() {
        let directive = run(kind: .relayRun, status: .completed, targets: ["NERVIU"], targetIndex: 0)

        #expect(directive.hasDelivered(targetAt: 0),
                "the mesh grew — the cursor simply never had anywhere to move to")
    }

    /// The cursor still means what it means for a run genuinely part-way
    /// through a queue.
    @Test func aRunningQueueChecksOffOnlyWhatItHasPassed() {
        let directive = run(
            kind: .surveyRun, status: .running,
            targets: ["TAU", "SHERATANON", "VEGA"], targetIndex: 1
        )

        #expect(directive.hasDelivered(targetAt: 0))
        #expect(!directive.hasDelivered(targetAt: 1), "this one is in progress, not done")
        #expect(!directive.hasDelivered(targetAt: 2))
    }

    /// **A cancelled run must not claim credit for where it never went.** This
    /// is the assertion that stops the fix from becoming "completed-ish runs
    /// check everything": a run stopped by an operator keeps showing exactly
    /// the targets it really reached.
    @Test("a run that stopped early shows only what it reached", arguments: [
        DirectiveStatus.cancelled, .needsAttention, .paused, .running,
    ])
    func anUnfinishedRunClaimsNothingExtra(_ status: DirectiveStatus) {
        let directive = run(
            kind: .surveyRun, status: status,
            targets: ["TAU", "SHERATANON", "VEGA"], targetIndex: 1
        )

        #expect(directive.hasDelivered(targetAt: 0))
        #expect(!directive.hasDelivered(targetAt: 1), "\(status) must not check off an unreached target")
        #expect(!directive.hasDelivered(targetAt: 2), "\(status) must not check off an unreached target")
    }

    /// A completed multi-target run has, by definition, delivered all of them —
    /// and survey runs DO advance the cursor, so this agrees with the cursor
    /// rather than overriding it.
    @Test func aCompletedQueueIsFullyChecked() {
        let directive = run(
            kind: .surveyRun, status: .completed,
            targets: ["TAU", "SHERATANON"], targetIndex: 2
        )

        #expect(directive.hasDelivered(targetAt: 0))
        #expect(directive.hasDelivered(targetAt: 1))
    }
}
