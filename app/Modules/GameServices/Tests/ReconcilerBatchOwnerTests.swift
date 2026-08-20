//
//  ReconcilerBatchOwnerTests.swift
//  Replicould — GameServices
//
//  One `enqueue_print` with `quantity: N` records a single owned op, so jobs
//  2…N reach the platen with that op already closed and are adopted from the
//  snapshot. `batchOwner` is what keeps the run that ordered them nameable.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameServices

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

@Suite struct ReconcilerBatchOwnerTests {

    private static let bench = "965AC2C3"
    private static let printed = "ami_survey_controller"

    private func batchOp(
        id: String,
        quantity: Int,
        deviceType: String = printed,
        directive: String? = "D-7",
        startedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> Operation {
        Operation(
            id: id, entityCode: Self.bench, kind: OperationKind.print.rawValue,
            status: OperationStatus.completed, source: OperationSource.event,
            startedAt: startedAt, completesAt: startedAt.addingTimeInterval(600),
            lastConfirmedAt: startedAt,
            detail: .object([
                "params": .object([
                    "device_type": .string(deviceType),
                    "quantity": .number(Double(quantity)),
                ])
            ]),
            directiveID: directive,
            step: "printing"
        )
    }

    /// A job the bench already adopted from a batch — untyped, as the adoption
    /// path writes it.
    private func adoptedOp(id: String, directive: String?, startedAt: Date) -> Operation {
        Operation(
            id: id, entityCode: Self.bench, kind: OperationKind.print.rawValue,
            status: OperationStatus.completed, source: OperationSource.poll,
            startedAt: startedAt, completesAt: startedAt.addingTimeInterval(600),
            lastConfirmedAt: startedAt, detail: .object([:]),
            directiveID: directive
        )
    }

    @Test("job 2 of a quantity-2 batch inherits the run that ordered the batch")
    func secondJobInheritsOwner() {
        let owner = Reconciler.batchOwner(
            printing: Self.printed,
            startedAt: Date(timeIntervalSince1970: 700),
            among: [batchOp(id: "A", quantity: 2)]
        )

        #expect(owner?.directiveID == "D-7")
        #expect(owner?.step == "printing")
    }

    @Test("a batch that has run every unit it asked for adopts nobody")
    func exhaustedBatchInheritsNothing() {
        let owner = Reconciler.batchOwner(
            printing: Self.printed,
            startedAt: Date(timeIntervalSince1970: 1_400),
            among: [
                batchOp(id: "A", quantity: 2),
                adoptedOp(id: "B", directive: "D-7", startedAt: Date(timeIntervalSince1970: 700)),
            ]
        )

        #expect(owner == nil)
    }

    /// A single-unit print needs no inheritance — its own op is promoted in
    /// place — so claiming one would attribute a later job to a finished run.
    @Test("a single-unit print adopts nobody")
    func singleUnitInheritsNothing() {
        let owner = Reconciler.batchOwner(
            printing: Self.printed,
            startedAt: Date(timeIntervalSince1970: 700),
            among: [batchOp(id: "A", quantity: 1)]
        )

        #expect(owner == nil)
    }

    @Test("a batch printing a different type adopts nobody")
    func differentTypeInheritsNothing() {
        let owner = Reconciler.batchOwner(
            printing: "mining_drone",
            startedAt: Date(timeIntervalSince1970: 700),
            among: [batchOp(id: "A", quantity: 2)]
        )

        #expect(owner == nil)
    }

    @Test("an unowned batch adopts nobody")
    func unownedBatchInheritsNothing() {
        let owner = Reconciler.batchOwner(
            printing: Self.printed,
            startedAt: Date(timeIntervalSince1970: 700),
            among: [batchOp(id: "A", quantity: 2, directive: nil)]
        )

        #expect(owner == nil)
    }

    /// A job that started before the batch was dispatched belongs to whatever
    /// came before it, not to the batch.
    @Test("a job predating the batch adopts nobody")
    func jobBeforeBatchInheritsNothing() {
        let owner = Reconciler.batchOwner(
            printing: Self.printed,
            startedAt: Date(timeIntervalSince1970: 100),
            among: [batchOp(id: "A", quantity: 2, startedAt: Date(timeIntervalSince1970: 4_000))]
        )

        #expect(owner == nil)
    }

    /// The batch is the most recent one dispatched, not the first on the bench.
    @Test("a newer batch outranks an older one on the same bench")
    func newestBatchWins() {
        let owner = Reconciler.batchOwner(
            printing: Self.printed,
            startedAt: Date(timeIntervalSince1970: 5_000),
            among: [
                batchOp(id: "OLD", quantity: 2, directive: "D-OLD"),
                adoptedOp(id: "OLD-2", directive: "D-OLD", startedAt: Date(timeIntervalSince1970: 700)),
                batchOp(id: "NEW", quantity: 2, directive: "D-NEW", startedAt: Date(timeIntervalSince1970: 4_000)),
            ]
        )

        #expect(owner?.directiveID == "D-NEW")
    }

    /// End to end: the bench starts job 2 with the batch's own op already
    /// closed, and the row adopted from the snapshot still names the run.
    @Test func adoptedJobCarriesTheBatchOwner() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { self.batchOp(id: "batch", quantity: 2) }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(Self.printingDevice(Self.bench))
        }

        let adopted = try await database.read { db in
            try Operation.where { $0.entityCode.eq(Self.bench) && $0.status.eq(OperationStatus.active) }
                .fetchOne(db)
        }
        #expect(adopted?.directiveID == "D-7")
        #expect(adopted?.step == "printing")
        // Untyped still: `selectCompletableOp` relies on an adopted op naming no
        // device type, and the governor's de-dup key must not collide.
        #expect(adopted?.printedDeviceType == nil)
        #expect(adopted?.paramsDigest == nil)
    }

    /// A bench printing with no batch behind it still adopts an ownerless op.
    @Test func adoptedJobWithoutABatchNamesNobody() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(Self.printingDevice(Self.bench))
        }

        let adopted = try await database.read { db in
            try Operation.where { $0.entityCode.eq(Self.bench) }.fetchOne(db)
        }
        #expect(adopted != nil)
        #expect(adopted?.directiveID == nil)
    }

    /// A device snapshot mid-`printing`, matching `ReconcilerOperationTests`.
    static func printingDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1",
            status: "printing (ami_survey_controller)",
            location: "ATIANFU-BELT-1", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "printing": .object([
                    "started_at": .string("2026-06-28T23:52:27-05:00"),
                    "completes_at": .string("2026-06-29T00:17:27-05:00"),
                    "device_type": .string("ami_survey_controller"),
                ])
            ]),
            updatedAt: Date(timeIntervalSince1970: 0),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }
}
