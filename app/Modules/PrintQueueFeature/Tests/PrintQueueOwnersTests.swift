//
//  PrintQueueOwnersTests.swift
//  Replicould — PrintQueueFeature
//

import Foundation
import GameModels
import Testing

@testable import PrintQueueFeature

@Suite("Print queue owners")
struct PrintQueueOwnersTests {

    @Test("a bench's open print names the run that ordered it")
    func openPrintNamesItsRun() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: "D-7")],
            directives: [directive(id: "D-7", kind: .mineFleetPrint)]
        )

        #expect(owners == ["B1": ["Mine Fleet Print"]])
    }

    @Test("a job nobody owns names nobody")
    func unownedJobNamesNobody() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: nil)], directives: []
        )

        #expect(owners.isEmpty)
    }

    /// A directive with an empty-string id existing elsewhere must not be
    /// matched by a nil `directiveID` coalesced to `""`.
    @Test("a job nobody owns names nobody, even beside an empty-id directive")
    func unownedJobIgnoresEmptyIDDirective() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: nil)],
            directives: [directive(id: "", kind: .mineFleetPrint)]
        )

        #expect(owners.isEmpty)
    }

    /// An op stamped with a directive that has since been deleted must not
    /// invent a title, and must not crash.
    @Test("an op whose directive is gone names nobody")
    func missingDirectiveNamesNobody() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: "D-GONE")], directives: []
        )

        #expect(owners.isEmpty)
    }

    @Test("two runs on one bench are both named, in a stable order")
    func twoRunsBothNamed() {
        let owners = PrintQueueOwners.merge(
            operations: [
                printOp(on: "B1", directive: "D-9", id: "OP-2"),
                printOp(on: "B1", directive: "D-7", id: "OP-1")
            ],
            directives: [
                directive(id: "D-7", kind: .mineFleetPrint),
                directive(id: "D-9", kind: .restockRun)
            ]
        )

        // Oldest first, which is the order the bench will work them.
        #expect(owners == ["B1": ["Mine Fleet Print", "Relay Restock"]])
    }

    @Test("a completed print names nobody")
    func completedPrintNamesNobody() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: "D-7", status: .completed)],
            directives: [directive(id: "D-7", kind: .mineFleetPrint)]
        )

        #expect(owners.isEmpty)
    }

    @Test("a non-print op on the bench names nobody")
    func nonPrintOpNamesNobody() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: "D-7", kind: OperationKind.mine.rawValue)],
            directives: [directive(id: "D-7", kind: .mineFleetPrint)]
        )

        #expect(owners.isEmpty)
    }
}

/// `startedAt` is derived from the trailing digits of `id` ("OP-1" → 1s past
/// the epoch), so ordering in a test's fixture list is legible from the ids.
private func printOp(
    on deviceCode: String,
    directive directiveID: String?,
    id: String = "OP-1",
    status: OperationStatus = .active,
    kind: String = OperationKind.print.rawValue
) -> GameModels.Operation {
    let ordinal = Double(id.split(separator: "-").last.flatMap { Int($0) } ?? 0)
    return GameModels.Operation(
        id: id,
        entityCode: deviceCode,
        kind: kind,
        status: status,
        source: .event,
        startedAt: Date(timeIntervalSince1970: ordinal),
        completesAt: nil,
        lastConfirmedAt: Date(),
        detail: .object([:]),
        directiveID: directiveID
    )
}

private func directive(id: String, kind: DirectiveKind) -> Directive {
    Directive(
        id: id,
        kind: kind,
        status: .running,
        deviceCode: "VESSEL-1",
        targets: [],
        targetIndex: 0,
        step: "",
        stepStartedAt: Date(),
        returnToOrigin: false,
        originDesignation: nil,
        attentionReason: nil,
        createdAt: Date(),
        updatedAt: Date()
    )
}
