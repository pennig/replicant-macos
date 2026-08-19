//
//  StepContextTests.swift
//  Replicould — DirectiveEngine
//
//  The frame sub-machines read, and the one derivation it owns: the owner.
//

import Foundation
import GameModels
import GameServices
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)
private let stepStart = now.addingTimeInterval(-90)

private func row(step: String = "travelling") -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: "C1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["AINALRAM-BELT-1"], targetIndex: 0, step: step, stepStartedAt: stepStart,
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: stepStart, updatedAt: now, theatreDepot: nil
    )
}

private func operation(_ entityCode: String, directiveID: String?) -> GameModels.Operation {
    GameModels.Operation(
        id: "OP-\(entityCode)", entityCode: entityCode, kind: OperationKind.travel.rawValue, status: .active,
        source: .optimistic, startedAt: stepStart, completesAt: now.addingTimeInterval(60),
        lastConfirmedAt: stepStart, detail: .object([:]), directiveID: directiveID,
        step: "travelling", paramsDigest: nil
    )
}

@Suite("Step context")
struct StepContextTests {
    /// The owner a sub-machine reasons with must be the one `DirectiveExecutor`
    /// stamps, or a de-dup window and a guard disagree about the same command.
    @Test("the derived owner is the one the executor stamps")
    func ownerMatchesTheExecutor() {
        let directive = row()
        let ctx = StepContext(
            directive: directive,
            world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
            step: "travelling"
        )
        #expect(ctx.owner == CommandOwner(
            directiveID: directive.id, step: directive.step, since: directive.stepStartedAt
        ))
    }

    @Test("elapsed measures the current step, not the run")
    func elapsedMeasuresTheStep() {
        let ctx = StepContext(
            directive: row(),
            world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
            step: "travelling"
        )
        #expect(ctx.elapsed == 90)
    }

    /// The two guards are different questions. Travel sites ask the first,
    /// print sites ask the second; conflating them silently changes 13 sites.
    @Test("the unowned guard sees a co-tenant's op and the owned one does not")
    func theTwoGuardsDiffer() {
        let ctx = StepContext(
            directive: row(),
            world: WorldSnapshot(
                devices: [:],
                openOperations: ["C1": operation("C1", directiveID: "D2")],
                now: now
            ),
            step: "travelling"
        )
        #expect(ctx.openOperation(for: "C1") != nil)
        #expect(ctx.ownedOperation(for: "C1") == nil)
    }
}
